#!/bin/sh

# Deploy module: orchestrate remote Kubernetes cluster installation via SSH
# SSH infrastructure is provided by lib/ssh.sh (loaded before this module).
#
# === Sections ===
# 1. Dry-run display                        (~line 11)
# 2. Remote orchestration (deploy_cluster)   (~line 73)
# 3. CLI parsing & help                     (~line 337)
#
# Token extraction -> lib/join_token.sh

# --- Main Orchestration ---

# Show dry-run deployment plan
deploy_dry_run() {
    log_info "=== Deploy Dry-Run Plan ==="
    log_info ""

    _log_node_list "Control-Plane Nodes" "$DEPLOY_CONTROL_PLANES"
    log_info ""

    if [ -n "$DEPLOY_WORKERS" ]; then
        _log_node_list "Worker Nodes" "$DEPLOY_WORKERS"
    else
        log_info "Worker Nodes: (none)"
    fi
    log_info ""

    _log_ssh_settings
    log_info ""

    if [ -n "$DEPLOY_PASSTHROUGH_ARGS" ]; then
        log_info "Passthrough Args: $DEPLOY_PASSTHROUGH_ARGS"
        log_info ""
    fi

    local cp_count
    cp_count=$(_csv_count "$DEPLOY_CONTROL_PLANES")
    local cp0
    cp0=$(_csv_get "$DEPLOY_CONTROL_PLANES" 0)
    log_info "Orchestration Plan:"
    log_info "  1. Generate bundle (all modules → single file)"
    log_info "  2. Check SSH connectivity to all nodes"
    log_info "  3. Transfer bundle to all nodes"
    log_info "  4. Init first control-plane: ${cp0}"
    if [ "$cp_count" -gt 1 ]; then
        log_info "  5. Extract join token"
        log_info "  6. Join additional control-planes (sequential):"
        _i=1
        while [ "$_i" -lt "$cp_count" ]; do
            local node
            node=$(_csv_get "$DEPLOY_CONTROL_PLANES" "$_i")
            log_info "     - ${node}"
            _i=$((_i + 1))
        done
    else
        log_info "  5. Extract join token"
    fi
    if [ -n "$DEPLOY_WORKERS" ]; then
        log_info "  7. Join workers (parallel):"
        _i=0
        local w_count
        w_count=$(_csv_count "$DEPLOY_WORKERS")
        while [ "$_i" -lt "$w_count" ]; do
            local node
            node=$(_csv_get "$DEPLOY_WORKERS" "$_i")
            log_info "     - $node"
            _i=$((_i + 1))
        done
    fi
    log_info "  8. Show summary"
    log_info ""
    log_info "=== End of dry-run (no changes made) ==="
}

# Build a join command string with common join arguments.
# Usage: join_cmd=$(_build_join_cmd <sudo_prefix> <bundle_path>)
# Requires: _JOIN_TOKEN, _JOIN_ADDR, _JOIN_HASH (set by _extract_join_info)
_build_join_cmd() {
    local _sudo="$1" _bundle="$2"
    local _cmd="${_sudo}sh ${_bundle} join"
    _cmd="${_cmd} --join-token $(_posix_shell_quote "$_JOIN_TOKEN")"
    _cmd="${_cmd} --join-address $(_posix_shell_quote "$_JOIN_ADDR")"
    _cmd="${_cmd} --discovery-token-hash $(_posix_shell_quote "$_JOIN_HASH")"
    printf '%s' "$_cmd"
}

# Main deploy orchestration
deploy_cluster() {
    local cp_count w_count
    cp_count=$(_csv_count "$DEPLOY_CONTROL_PLANES")
    w_count=0
    [ -n "$DEPLOY_WORKERS" ] && w_count=$(_csv_count "$DEPLOY_WORKERS")

    # Build combined node list (comma-separated)
    _DEPLOY_ALL_NODES="$DEPLOY_CONTROL_PLANES"
    [ -n "$DEPLOY_WORKERS" ] && _DEPLOY_ALL_NODES="${_DEPLOY_ALL_NODES},${DEPLOY_WORKERS}"
    local all_count
    all_count=$(_csv_count "$_DEPLOY_ALL_NODES")

    # Calculate total orchestration steps: ssh-check, bundle-transfer, init, extract-token,
    # [join-cps], [join-workers], cleanup-remote, summary
    local total_steps=5
    [ "$cp_count" -gt 1 ] && total_steps=$((total_steps + 1))
    [ "$w_count" -gt 0 ] && total_steps=$((total_steps + 1))
    # State/resume support (only when --resume is enabled)
    if [ "${RESUME_ENABLED:-false}" = true ]; then
        local resume_file
        resume_file=$(_state_find_resume "deploy")
        if [ -n "$resume_file" ]; then
            _state_load "$resume_file"
            log_info "Resuming previous deploy operation..."
        else
            log_info "No resumable deploy state found, starting fresh."
            _state_init "deploy"
        fi
    fi
    _state_set "cp_count" "$cp_count"
    _state_set "w_count" "$w_count"

    _audit_log "deploy" "started" "cp=${cp_count} workers=${w_count}"
    log_info "Deploying Kubernetes cluster: ${cp_count} control-plane(s), ${w_count} worker(s)"

    local _step=0

    # --- Step 1: SSH connectivity check ---
    _step=$((_step + 1))
    log_info "Step ${_step}/${total_steps}: Checking SSH connectivity..."
    if ! _init_remote_session "deploy" "$_DEPLOY_ALL_NODES"; then
        return 1
    fi

    # --- Step 2: Generate and transfer bundle ---
    # Always regenerate (even on resume), because bundle paths are
    # process-local and remote temp dirs are cleaned on exit.
    _step=$((_step + 1))
    log_info "Step ${_step}/${total_steps}: Generating and transferring bundle..."
    if ! _generate_and_transfer_bundle "deploy"; then
        return 1
    fi

    # --- Step 3: Init first control-plane ---
    _step=$((_step + 1))
    local cp0
    cp0=$(_csv_get "$DEPLOY_CONTROL_PLANES" 0)
    _parse_node_address "$cp0"
    local cp1_user="$_NODE_USER" cp1_host="$_NODE_HOST"

    if ! _state_is_step_done "init_cp"; then
        log_info "Step ${_step}/${total_steps}: Initializing first control-plane..."

        # Transfer kubeadm config patch file to remote if specified
        local _remote_patch_path=""
        if [ -n "${KUBEADM_CONFIG_PATCH:-}" ] && [ -f "$KUBEADM_CONFIG_PATCH" ]; then
            local _rdir
            _rdir=$(_bundle_dir_lookup "$cp1_host")
            _remote_patch_path="${_rdir}/kubeadm-config-patch.yaml"
            log_info "  Transferring kubeadm config patch to ${cp1_host}..."
            if ! _deploy_scp "$KUBEADM_CONFIG_PATCH" "$cp1_user" "$cp1_host" "$_remote_patch_path"; then
                log_error "Failed to transfer kubeadm config patch to ${cp1_host}"
                return 1
            fi
            # Rewrite passthrough args: replace local path with remote path
            DEPLOY_PASSTHROUGH_ARGS=$(printf '%s\n' "$DEPLOY_PASSTHROUGH_ARGS" | while IFS= read -r _line; do
                if [ "$_line" = "$KUBEADM_CONFIG_PATCH" ]; then
                    echo "$_remote_patch_path"
                else
                    echo "$_line"
                fi
            done)
        fi

        # Build init command with passthrough args (shell-escaped)
        local remote_bundle
        remote_bundle="$(_bundle_dir_lookup "$cp1_host")/setup-k8s.sh"
        local sudo_pfx; sudo_pfx=$(_sudo_prefix "$cp1_user")
        local init_cmd="${sudo_pfx}sh ${remote_bundle} init"
        # If multiple CPs, enable HA
        if [ "$cp_count" -gt 1 ]; then
            init_cmd="${init_cmd} --ha"
        fi
        init_cmd=$(_append_passthrough_to_cmd "$init_cmd" "$DEPLOY_PASSTHROUGH_ARGS")

        if ! _deploy_exec_remote "$cp1_user" "$cp1_host" "kubeadm init" "$init_cmd"; then
            log_error "First control-plane initialization failed. Aborting."
            if [ "${COLLECT_DIAGNOSTICS:-false}" = true ]; then
                _collect_diagnostics "$cp1_user" "$cp1_host" "/tmp/setup-k8s-diag-init-$(date +%s)" || true
            fi
            return 1
        fi
        _state_mark_step "init_cp" "done"
    else
        log_info "Step ${_step}/${total_steps}: Initializing first control-plane... (skipped, resumed)"
    fi

    # --- Step 4: Extract join token ---
    _step=$((_step + 1))
    log_info "Step ${_step}/${total_steps}: Extracting join information..."
    if ! _extract_join_info "$cp1_user" "$cp1_host"; then
        log_error "Failed to extract join info. Aborting."
        return 1
    fi

    # --- Step 5: Join additional control-planes (sequential) ---
    if [ "$cp_count" -gt 1 ]; then
        _step=$((_step + 1))
        log_info "Step ${_step}/${total_steps}: Joining additional control-planes..."
        _i=1
        while [ "$_i" -lt "$cp_count" ]; do
            local node
            node=$(_csv_get "$DEPLOY_CONTROL_PLANES" "$_i")
            _parse_node_address "$node"

            if _state_is_step_done "join_cp_${_NODE_HOST}"; then
                log_info "  [${_NODE_HOST}] Control-plane join... (skipped, resumed)"
                _i=$((_i + 1))
                continue
            fi

            local node_bundle
            node_bundle="$(_bundle_dir_lookup "$_NODE_HOST")/setup-k8s.sh"
            local sudo_pfx; sudo_pfx=$(_sudo_prefix "$_NODE_USER")
            local join_cmd
            join_cmd=$(_build_join_cmd "$sudo_pfx" "$node_bundle")
            join_cmd="${join_cmd} --control-plane"
            join_cmd="${join_cmd} --certificate-key $(_posix_shell_quote "$_CERT_KEY")"
            # Pass through HA and other args (shell-escaped)
            join_cmd=$(_append_passthrough_to_cmd "$join_cmd" "$DEPLOY_PASSTHROUGH_ARGS")

            if ! _deploy_exec_remote "$_NODE_USER" "$_NODE_HOST" "join control-plane" "$join_cmd"; then
                log_error "Control-plane join failed for ${_NODE_HOST}. Aborting."
                if [ "${COLLECT_DIAGNOSTICS:-false}" = true ]; then
                    _collect_diagnostics "$_NODE_USER" "$_NODE_HOST" "/tmp/setup-k8s-diag-join-cp-$(date +%s)" || true
                fi
                return 1
            fi
            _state_mark_step "join_cp_${_NODE_HOST}" "done"
            _i=$((_i + 1))
        done
    fi

    # --- Step 6: Join workers (parallel) ---
    local worker_failed=false
    if [ "$w_count" -gt 0 ]; then
        _step=$((_step + 1))
        log_info "Step ${_step}/${total_steps}: Joining worker nodes (parallel)..."
        local worker_pids="" worker_hosts=""

        _i=0
        while [ "$_i" -lt "$w_count" ]; do
            local node
            node=$(_csv_get "$DEPLOY_WORKERS" "$_i")
            _parse_node_address "$node"
            local w_user="$_NODE_USER" w_host="$_NODE_HOST"

            local w_bundle
            w_bundle="$(_bundle_dir_lookup "$w_host")/setup-k8s.sh"
            local w_sudo; w_sudo=$(_sudo_prefix "$w_user")
            local join_cmd
            join_cmd=$(_build_join_cmd "$w_sudo" "$w_bundle")
            join_cmd=$(_append_passthrough_filtered "$join_cmd" "$DEPLOY_PASSTHROUGH_ARGS" "--ha-vip --ha-interface")

            # Run in background subshell
            (
                _deploy_exec_remote "$w_user" "$w_host" "join worker" "$join_cmd"
            ) &
            worker_pids="${worker_pids}${worker_pids:+ }$!"
            worker_hosts="${worker_hosts}${worker_hosts:+ }${w_host}"
            _i=$((_i + 1))
        done

        # Wait for all worker joins
        local _pi=0
        for _pid in $worker_pids; do
            _pi=$((_pi + 1))
            local _w_host
            _w_host=$(echo "$worker_hosts" | tr ' ' '\n' | sed -n "${_pi}p")
            if ! wait "$_pid"; then
                log_error "Worker join failed for ${_w_host}"
                worker_failed=true
            fi
        done
    fi

    # --- Post-deploy health check ---
    log_info ""
    _health_check_cluster "$cp1_user" "$cp1_host" --post || true

    # Verify expected node count (fatal if mismatch)
    local node_count_ok=true
    _verify_node_count "$cp1_user" "$cp1_host" "$all_count" || node_count_ok=false

    # --- Step 7: Clean up remote bundle directories ---
    _step=$((_step + 1))
    log_info "Step ${_step}/${total_steps}: Cleaning up remote bundle directories..."
    _cleanup_remote_bundle_dirs
    _pop_cleanup

    # --- Step 8: Summary ---
    log_info ""
    log_info "=== Deployment Summary ==="
    log_info ""
    _log_node_list "Control-Plane Nodes" "$DEPLOY_CONTROL_PLANES"
    log_info ""
    if [ "$w_count" -gt 0 ]; then
        _log_node_list "Worker Nodes" "$DEPLOY_WORKERS"
        log_info ""
    fi

    # Retrieve kubeconfig from first CP
    local scp_display="scp"
    [ "$DEPLOY_SSH_PORT" != "22" ] && scp_display="$scp_display -P $DEPLOY_SSH_PORT"
    [ -n "$DEPLOY_SSH_KEY" ] && scp_display="$scp_display -i $DEPLOY_SSH_KEY"
    # shellcheck disable=SC2088  # tilde is intentional display text, not expanded
    scp_display="$scp_display ${cp1_user}@${cp1_host}:/etc/kubernetes/admin.conf ~/.kube/config"
    log_info "To access the cluster from this machine:"
    log_info "  ${scp_display}"
    log_info ""
    log_info "Next steps:"
    log_info "  1. Install a CNI plugin (e.g., Calico, Cilium, Flannel)"
    log_info "  2. Verify: kubectl get nodes"
    log_info "=========================="

    if [ "$worker_failed" = true ] || [ "$node_count_ok" = false ]; then
        _state_set "status" "failed"
        if [ "$worker_failed" = true ]; then
            _audit_log "deploy" "failed" "some worker joins failed"
            log_error "Some worker joins failed. Check logs above."
        fi
        if [ "$node_count_ok" = false ]; then
            _audit_log "deploy" "failed" "node count mismatch"
            log_error "Not all nodes registered. Check logs above."
        fi
        return 1
    fi

    # Clean up session-scoped known_hosts
    _teardown_session_known_hosts
    _pop_cleanup

    _state_complete
    _audit_log "deploy" "completed" "cp=${cp_count} workers=${w_count}"
    log_info "Cluster deployment completed successfully!"
    return 0
}

# === Deploy argument parsing (moved from lib/validation.sh) ===
show_deploy_help() {
    echo "Usage: $0 deploy [options]"
    echo ""
    echo "Deploy a Kubernetes cluster across remote nodes via SSH."
    echo ""
    echo "Required:"
    echo "  --control-planes IPs    Comma-separated list of control-plane nodes (user@ip or ip)"
    echo ""
    echo "Optional:"
    echo "  --workers IPs           Comma-separated list of worker nodes (user@ip or ip)"
    _show_common_ssh_help "  "
    echo "  --ha-vip ADDRESS        VIP address for HA (required when >1 control-plane)"
    echo "  --ha-interface IFACE    Network interface for VIP (auto-detected on remote)"
    echo "  --cri RUNTIME           Container runtime (containerd or crio)"
    echo "  --proxy-mode MODE       Kube-proxy mode (iptables, ipvs, or nftables)"
    echo "  --distro FAMILY         Override distro family detection"
    echo "  --swap-enabled          Keep swap enabled (K8s 1.28+)"
    echo "  --enable-completion BOOL  Enable shell completion setup (default: true)"
    echo "  --install-helm BOOL     Install Helm package manager (default: false)"
    echo "  --install-kustomize BOOL  Install Kustomize (default: false)"
    echo "  --completion-shells LIST  Shells to configure (auto, bash, zsh, fish, or comma-separated)"
    echo "  --kubernetes-version VER Kubernetes version (e.g., 1.32)"
    echo "  --pod-network-cidr CIDR Pod network CIDR"
    echo "  --service-cidr CIDR     Service CIDR"
    echo "  --resume                Resume a previously interrupted deploy"
    _show_help_footer "  " "Show deployment plan and exit"
    echo ""
    echo "Examples:"
    echo "  $0 deploy --control-planes 10.0.0.1 --workers 10.0.0.2,10.0.0.3 --ssh-key ~/.ssh/id_rsa"
    echo "  $0 deploy --control-planes 10.0.0.1,10.0.0.2,10.0.0.3 --workers 10.0.0.4 --ha-vip 10.0.0.100"
    echo "  $0 deploy --control-planes admin@10.0.0.1 --workers ubuntu@10.0.0.2"
    exit "${1:-0}"
}

# Parse command line arguments for deploy
parse_deploy_args() {
    while [ $# -gt 0 ]; do
        case $1 in
            --help|-h)
                show_deploy_help
                ;;
            --ha-vip)
                _require_value $# "$1" "${2:-}"
                DEPLOY_PASSTHROUGH_ARGS=$(_passthrough_add_pair "$DEPLOY_PASSTHROUGH_ARGS" "--ha-vip" "$2")
                shift 2
                ;;
            --ha-interface)
                _require_value $# "$1" "${2:-}"
                DEPLOY_PASSTHROUGH_ARGS=$(_passthrough_add_pair "$DEPLOY_PASSTHROUGH_ARGS" "--ha-interface" "$2")
                shift 2
                ;;
            --distro)
                _require_value $# "$1" "${2:-}"
                DEPLOY_PASSTHROUGH_ARGS=$(_passthrough_add_pair "$DEPLOY_PASSTHROUGH_ARGS" "$1" "$2")
                shift 2
                ;;
            --cri|--proxy-mode|--kubernetes-version|--pod-network-cidr|--service-cidr|--apiserver-advertise-address|--control-plane-endpoint|--kubeadm-config-patch|--api-server-extra-sans|--kubelet-node-ip)
                _require_value $# "$1" "${2:-}"
                DEPLOY_PASSTHROUGH_ARGS=$(_passthrough_add_pair "$DEPLOY_PASSTHROUGH_ARGS" "$1" "$2")
                shift 2
                ;;
            --swap-enabled)
                DEPLOY_PASSTHROUGH_ARGS=$(_passthrough_add_flag "$DEPLOY_PASSTHROUGH_ARGS" "$1")
                shift
                ;;
            --enable-completion|--install-helm|--install-kustomize|--completion-shells)
                _require_value $# "$1" "${2:-}"
                DEPLOY_PASSTHROUGH_ARGS=$(_passthrough_add_pair "$DEPLOY_PASSTHROUGH_ARGS" "$1" "$2")
                shift 2
                ;;
            *)
                if _parse_remote_ssh_args $# "$1" "${2:-}"; then
                    shift "$_REMOTE_SSH_SHIFT"
                else
                    log_error "Unknown deploy option: $1"
                    show_deploy_help 1
                fi
                ;;
        esac
    done
}

# Validate deploy arguments
validate_deploy_args() {
    # --control-planes is required
    if [ -z "$DEPLOY_CONTROL_PLANES" ]; then
        log_error "--control-planes is required for deploy"
        exit 1
    fi

    _validate_remote_node_args

    # Count control-plane nodes
    local cp_count
    cp_count=$(_csv_count "$DEPLOY_CONTROL_PLANES")

    # Check --ha-vip in passthrough args
    local has_ha_vip=false
    case "$DEPLOY_PASSTHROUGH_ARGS" in
        *--ha-vip*) has_ha_vip=true ;;
    esac

    # If >1 CP, --ha-vip is required
    if [ "$cp_count" -gt 1 ] && [ "$has_ha_vip" = false ]; then
        log_error "--ha-vip is required when using multiple control-plane nodes"
        exit 1
    fi

    # If only 1 CP, --ha-vip is not applicable
    if [ "$cp_count" -eq 1 ] && [ "$has_ha_vip" = true ]; then
        log_error "--ha-vip requires multiple control-plane nodes (got 1)"
        exit 1
    fi
}
