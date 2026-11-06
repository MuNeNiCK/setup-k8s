#!/bin/sh

# Deploy module: orchestrate remote Kubernetes cluster installation via SSH
# SSH infrastructure is provided by lib/remote/ssh.sh (loaded before this module).
#
# === Sections ===
# 1. Dry-run display                        (~line 11)
# 2. Remote orchestration (deploy_cluster)   (~line 73)
# 3. CLI parsing & help                     (~line 337)
#
# Token extraction -> lib/node/kubeadm.sh

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

# Run a setup-k8s subcommand on a node with the forwarded deploy options
# (minus <drop>) and the node's copy of the kubeadm patches.
# Usage: _deploy_remote_run <drop> <node> <description> <subcommand> [args...]
_deploy_remote_run() {
    local drop="$1" node="$2" desc="$3"
    shift 3
    if [ -n "${KUBEADM_PATCHES_DIR:-}" ]; then
        remote_run --forward "$DEPLOY_PASSTHROUGH_ARGS" --drop "$drop" "$node" "$desc" "$@" \
            --kubeadm-patches "$(remote_node_dir "$node")/kubeadm-patches"
    else
        remote_run --forward "$DEPLOY_PASSTHROUGH_ARGS" --drop "$drop" "$node" "$desc" "$@"
    fi
}

# kube-proxy runs in the cluster's mode on every node. When the mode was not
# given (auto), forward the mode the first control plane selected so that
# joining nodes are prepared for it, not for what their own kernel prefers.
# Usage: _deploy_pin_proxy_mode <first_cp>
_deploy_pin_proxy_mode() {
    case "$DEPLOY_PASSTHROUGH_ARGS" in
        *--proxy-mode*) return 0 ;;
    esac
    local mode
    mode=$(remote_exec "$1" "kubectl --kubeconfig=/etc/kubernetes/admin.conf -n kube-system get configmap kube-proxy -o jsonpath='{.data.config\\.conf}'" 2>/dev/null \
        | awk '/^mode:/ {gsub(/"/, "", $2); print $2}') || mode=""
    [ -n "$mode" ] || mode=iptables   # empty mode is kube-proxy's iptables default
    log_info "  Cluster kube-proxy mode: ${mode} (used for joining nodes)"
    DEPLOY_PASSTHROUGH_ARGS=$(_passthrough_add_pair "$DEPLOY_PASSTHROUGH_ARGS" --proxy-mode "$mode")
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
    # --- Step 2: Transfer setup-k8s.sh ---
    # Always transferred (even on resume): remote working directories are
    # removed when the session closes.
    _step=$((_step + 1))
    if ! remote_session_open "deploy" "$_DEPLOY_ALL_NODES"; then
        return 1
    fi
    if [ -n "${KUBEADM_PATCHES_DIR:-}" ] && ! remote_send_dir "$KUBEADM_PATCHES_DIR" kubeadm-patches; then
        log_error "Failed to transfer kubeadm patches"
        remote_session_close
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
            _remote_patch_path="$(remote_node_dir "$cp0")/kubeadm-config-patch.yaml"
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

        # Multiple control planes enable HA
        local init_ha=""
        if [ "$cp_count" -gt 1 ]; then init_ha="--ha"; fi
        # shellcheck disable=SC2086 # init_ha is empty or a single flag
        if ! _deploy_remote_run "" "$cp0" "kubeadm init" init $init_ha; then
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
    _deploy_pin_proxy_mode "$cp0"

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

            if ! _deploy_remote_run "" "$node" "join control-plane" \
                join --join-token "$_JOIN_TOKEN" --join-address "$_JOIN_ADDR" --discovery-token-hash "$_JOIN_HASH" \
                --control-plane --certificate-key "$_CERT_KEY"; then
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
            local w_host="$_NODE_HOST"

            if _state_is_step_done "join_worker_${w_host}"; then
                log_info "  [${w_host}] Worker join... (skipped, resumed)"
                _i=$((_i + 1))
                continue
            fi

            # Run in background subshell (HA settings apply to control planes only)
            (
                _deploy_remote_run "--ha-vip --ha-interface" "$node" "join worker" \
                    join --join-token "$_JOIN_TOKEN" --join-address "$_JOIN_ADDR" --discovery-token-hash "$_JOIN_HASH"
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
            if wait "$_pid"; then
                _state_mark_step "join_worker_${_w_host}" "done"
            else
                log_error "Worker join failed for ${_w_host}"
                worker_failed=true
            fi
        done
    fi

    # --- Verify the cluster (API server, etcd, every node registered) ---
    log_info ""
    local cluster_ok=true
    _verify_deployed_cluster "$cp1_user" "$cp1_host" "$all_count" || cluster_ok=false

    # --- Step 7: Clean up remote bundle directories ---
    _step=$((_step + 1))
    log_info "Step ${_step}/${total_steps}: Cleaning up remote working directories..."
    remote_session_close

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

    if [ "$worker_failed" = true ] || [ "$cluster_ok" = false ]; then
        _state_set "status" "failed"
        if [ "$worker_failed" = true ]; then
            _audit_log "deploy" "failed" "some worker joins failed"
            log_error "Some worker joins failed. Check logs above."
        fi
        if [ "$cluster_ok" = false ]; then
            _audit_log "deploy" "failed" "cluster verification failed"
            log_error "The cluster did not pass verification (API server, etcd, or node registration). Check logs above."
        fi
        return 1
    fi

    _state_complete
    _audit_log "deploy" "completed" "cp=${cp_count} workers=${w_count}"
    log_info "Cluster deployment completed successfully!"
    return 0
}

# === Deploy argument parsing ===
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
    echo "  --proxy-mode MODE       Kube-proxy mode (auto, iptables, ipvs, or nftables; default: auto)"
    echo "  --distro FAMILY         Override distro family detection"
    echo "  --swap-enabled          Keep swap enabled (Kubernetes 1.30+)"
    echo "  --enable-completion BOOL  Enable shell completion setup (default: true)"
    echo "  --install-helm BOOL     Install Helm package manager (default: false)"
    echo "  --install-kustomize BOOL  Install Kustomize (default: false)"
    echo "  --completion-shells LIST  Shells to configure (auto, bash, zsh, fish, or comma-separated)"
    echo "  --kubernetes-version VER Kubernetes version: MAJOR.MINOR or MAJOR.MINOR.PATCH (e.g., 1.37 or 1.37.2)"
    echo "  --prerelease            Install the next release from the prerelease channels"
    echo "  --image-repository REPO Pull control-plane images from REPO"
    echo "  --kubeadm-patches DIR   Apply kubeadm patches from local DIR on every node"
    echo "  --pod-network-cidr CIDR Pod network CIDR"
    echo "  --service-cidr CIDR     Service CIDR"
    echo "  --apiserver-advertise-address ADDR, --control-plane-endpoint ENDPOINT,"
    echo "  --api-server-extra-sans LIST, --kubeadm-config-patch FILE, --kubelet-node-ip IP"
    echo "                          Passed to init/join on the nodes (see 'init --help')"
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
            --kubeadm-patches)
                _require_value $# "$1" "${2:-}"
                if [ ! -d "$2" ]; then
                    log_error "--kubeadm-patches directory not found: $2"
                    exit 1
                fi
                KUBEADM_PATCHES_DIR=$(cd "$2" && pwd)
                shift 2
                ;;
            --prerelease)
                DEPLOY_PASSTHROUGH_ARGS=$(_passthrough_add_flag "$DEPLOY_PASSTHROUGH_ARGS" "$1")
                shift
                ;;
            --cri|--proxy-mode|--kubernetes-version|--image-repository|--pod-network-cidr|--service-cidr|--apiserver-advertise-address|--control-plane-endpoint|--kubeadm-config-patch|--api-server-extra-sans|--kubelet-node-ip)
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

# === Runner ===

_run_deploy() {
    _run_remote deploy parse_deploy_args validate_deploy_args deploy_dry_run deploy_cluster "$@"
}
