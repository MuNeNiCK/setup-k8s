#!/bin/sh

# Upgrade module: local upgrade logic, dry-run display, and CLI parsing.
# Remote orchestration -> lib/cluster/upgrade.sh
# Version helpers, node role detection, rollback -> lib/cluster/upgrade.sh
#
# === Sections ===
# 1. Local upgrade logic    (~line 12)
# 2. Dry-run display        (~line 70)
# 3. CLI parsing & help     (~line 145)

# --- Local Upgrade ---

# Upgrade the current node (run with sudo)
upgrade_node_local() {
    local role current_version
    role=$(_detect_node_role)
    current_version=$(_get_current_k8s_version)
    _validate_upgrade_version "$current_version" "$UPGRADE_TARGET_VERSION"

    local minor_version
    minor_version=$(_k8s_minor_version "$UPGRADE_TARGET_VERSION")
    # shellcheck disable=SC2034 # K8S_VERSION used by distro functions for repo URLs
    K8S_VERSION="$minor_version"

    log_info "Upgrading node (role: $role) from v${current_version} to v${UPGRADE_TARGET_VERSION}..."

    # 1. Upgrade kubeadm package
    log_info "Step 1: Upgrading kubeadm to ${UPGRADE_TARGET_VERSION}..."
    _dispatch "upgrade_kubeadm_${DISTRO_FAMILY}" "$UPGRADE_TARGET_VERSION"

    # 2. Run kubeadm upgrade
    if [ "$role" = "first-control-plane" ]; then
        log_info "Step 2: Running kubeadm upgrade apply v${UPGRADE_TARGET_VERSION}..."
        local _preflight_errors="ControlPlaneNodesReady,CreateJob"
        if [ "$(_detect_init_system)" != "systemd" ]; then
            _preflight_errors="${_preflight_errors},SystemVerification"
        fi
        kubeadm upgrade apply "v${UPGRADE_TARGET_VERSION}" --yes --ignore-preflight-errors="${_preflight_errors}"
    else
        log_info "Step 2: Running kubeadm upgrade node..."
        # On workers, the default kubelet kubeconfig may lack permissions to read
        # kubeadm-config ConfigMap (NodeRestriction). Use admin.conf if available,
        # or a temporarily transferred copy set via UPGRADE_ADMIN_CONF.
        local _kubeconfig_arg=""
        if [ -f /etc/kubernetes/admin.conf ]; then
            _kubeconfig_arg="--kubeconfig /etc/kubernetes/admin.conf"
        elif [ -n "${UPGRADE_ADMIN_CONF:-}" ] && [ -f "${UPGRADE_ADMIN_CONF}" ]; then
            _kubeconfig_arg="--kubeconfig ${UPGRADE_ADMIN_CONF}"
        fi
        # shellcheck disable=SC2086,SC2046 # intentional word splitting
        kubeadm upgrade node $_kubeconfig_arg $(_kubeadm_preflight_ignore_args)
    fi

    # 3. Upgrade kubelet + kubectl packages
    log_info "Step 3: Upgrading kubelet and kubectl to ${UPGRADE_TARGET_VERSION}..."
    _dispatch "upgrade_kubelet_kubectl_${DISTRO_FAMILY}" "$UPGRADE_TARGET_VERSION"

    # 4. Restart kubelet
    log_info "Step 4: Restarting kubelet..."
    _service_reload
    if ! _service_restart kubelet; then
        log_warn "kubelet restart returned non-zero. It may take a moment to stabilize."
    fi

    show_versions
    log_info "Node upgrade complete (role: $role)!"
}

# --- Dry-run ---

# Show dry-run upgrade plan
upgrade_dry_run() {
    log_info "=== Upgrade Dry-Run Plan ==="
    log_info ""
    log_info "Target Version: ${UPGRADE_TARGET_VERSION}"
    log_info ""

    local cp_count
    cp_count=$(_csv_count "$DEPLOY_CONTROL_PLANES")
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

    log_info "Orchestration Plan:"
    log_info "  1. Generate bundle (all modules -> single file)"
    log_info "  2. Check SSH connectivity to all nodes"
    log_info "  3. Transfer bundle to all nodes"
    log_info "  4. Get current version from first CP"
    log_info "  5. Run kubeadm upgrade plan (informational)"
    local step=5
    step=$((step + 1))
    log_info "  ${step}. Upgrade control-planes (sequential):"
    _i=0
    while [ "$_i" -lt "$cp_count" ]; do
        local node
        node=$(_csv_get "$DEPLOY_CONTROL_PLANES" "$_i")
        if [ "$UPGRADE_SKIP_DRAIN" != true ]; then
            log_info "     - drain ${node}"
        fi
        local _suffix=""
        [ "$_i" -eq 0 ] && _suffix=" (--first-control-plane)"
        log_info "     - upgrade ${node}${_suffix}"
        if [ "$UPGRADE_SKIP_DRAIN" != true ]; then
            log_info "     - uncordon ${node}"
        fi
        _i=$((_i + 1))
    done
    if [ -n "$DEPLOY_WORKERS" ]; then
        local w_count
        w_count=$(_csv_count "$DEPLOY_WORKERS")
        step=$((step + 1))
        log_info "  ${step}. Upgrade workers (sequential):"
        _i=0
        while [ "$_i" -lt "$w_count" ]; do
            local node
            node=$(_csv_get "$DEPLOY_WORKERS" "$_i")
            if [ "$UPGRADE_SKIP_DRAIN" != true ]; then
                log_info "     - drain $node"
            fi
            log_info "     - upgrade $node"
            if [ "$UPGRADE_SKIP_DRAIN" != true ]; then
                log_info "     - uncordon $node"
            fi
            _i=$((_i + 1))
        done
    fi
    step=$((step + 1))
    log_info "  ${step}. Verify: kubectl get nodes"
    step=$((step + 1))
    log_info "  ${step}. Show summary"
    log_info ""
    log_info "=== End of dry-run (no changes made) ==="
}

# === Upgrade argument parsing ===
# Help message for upgrade
show_upgrade_help() {
    echo "Usage: $0 upgrade [options]"
    echo ""
    echo "Upgrade a Kubernetes cluster to a new version."
    echo ""
    echo "Local mode (run on each node with sudo):"
    echo "  Required:"
    echo "    --kubernetes-version VER  Target version in MAJOR.MINOR.PATCH format (e.g., 1.33.2)"
    echo ""
    echo "  Optional:"
    echo "    --first-control-plane     Run 'kubeadm upgrade apply' (first CP only)"
    echo "    --skip-drain              Skip drain/uncordon (for single-node clusters)"
    echo "    --no-rollback             Disable automatic rollback on failure"
    echo "    --auto-step-upgrade       Automatically step through intermediate minor versions"
    echo "    --distro FAMILY           Override distro family detection"
    _show_help_footer "    "
    echo ""
    echo "Remote mode (orchestrate from local machine via SSH):"
    echo "  Required:"
    echo "    --control-planes IPs      Comma-separated control-plane nodes (user@ip or ip)"
    echo "    --kubernetes-version VER  Target version in MAJOR.MINOR.PATCH format"
    echo ""
    echo "  Optional:"
    echo "    --workers IPs             Comma-separated worker nodes (user@ip or ip)"
    _show_common_ssh_help "    "
    echo "    --skip-drain              Skip drain/uncordon for all nodes"
    echo "    --no-rollback             Disable automatic rollback on failure"
    echo "    --auto-step-upgrade       Automatically step through intermediate minor versions"
    echo "    --resume                  Resume a previously interrupted upgrade"
    _show_help_footer "    " "Show upgrade plan and exit"
    echo ""
    echo "Examples:"
    echo "  # Local: first control-plane"
    echo "  sudo $0 upgrade --kubernetes-version 1.33.2 --first-control-plane"
    echo ""
    echo "  # Local: additional control-plane or worker"
    echo "  sudo $0 upgrade --kubernetes-version 1.33.2"
    echo ""
    echo "  # Remote: full cluster upgrade"
    echo "  $0 upgrade --control-planes 10.0.0.1,10.0.0.2 --workers 10.0.0.3 --kubernetes-version 1.33.2 --ssh-key ~/.ssh/id_rsa"
    echo ""
    echo "  # Single-node (skip drain)"
    echo "  sudo $0 upgrade --kubernetes-version 1.33.2 --first-control-plane --skip-drain"
    exit "${1:-0}"
}

# Parse a single upgrade-specific option common to local and deploy modes.
# Sets _UPGRADE_ARG_SHIFT. Returns 0 if handled, 1 if not.
_UPGRADE_ARG_SHIFT=0
_parse_upgrade_common_arg() {
    local argc=$1 arg="$2" next="${3:-}"
    _UPGRADE_ARG_SHIFT=0
    case "$arg" in
        --kubernetes-version)
            _require_value "$argc" "$arg" "$next"
            if ! echo "$next" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
                log_error "--kubernetes-version for upgrade must be MAJOR.MINOR.PATCH (e.g., 1.33.2)"
                exit 1
            fi
            UPGRADE_TARGET_VERSION="$next"
            _UPGRADE_ARG_SHIFT=2
            ;;
        --skip-drain)
            UPGRADE_SKIP_DRAIN=true
            _UPGRADE_ARG_SHIFT=1
            ;;
        --no-rollback)
            # shellcheck disable=SC2034 # used by upgrade_orchestration.sh
            UPGRADE_NO_ROLLBACK=true
            _UPGRADE_ARG_SHIFT=1
            ;;
        --auto-step-upgrade)
            # shellcheck disable=SC2034 # used by upgrade_orchestration.sh
            UPGRADE_AUTO_STEP=true
            _UPGRADE_ARG_SHIFT=1
            ;;
        *) return 1 ;;
    esac
}

# Parse command line arguments for upgrade (local mode)
parse_upgrade_local_args() {
    while [ $# -gt 0 ]; do
        case $1 in
            --help|-h) show_upgrade_help ;;
            --first-control-plane)
                # shellcheck disable=SC2034 # used by upgrade_helpers.sh
                UPGRADE_FIRST_CONTROL_PLANE=true
                shift
                ;;
            *)
                if _parse_upgrade_common_arg $# "$1" "${2:-}"; then
                    shift "$_UPGRADE_ARG_SHIFT"
                elif _is_distro_flag "$1"; then
                    _parse_distro_flag $# "$1" "${2:-}"
                    shift "$_DISTRO_SHIFT"
                else
                    log_error "Unknown upgrade option: $1"
                    show_upgrade_help 1
                fi
                ;;
        esac
    done
    if [ -z "$UPGRADE_TARGET_VERSION" ]; then
        log_error "--kubernetes-version is required for upgrade"
        exit 1
    fi
}

# Parse command line arguments for upgrade (remote/deploy mode)
parse_upgrade_deploy_args() {
    while [ $# -gt 0 ]; do
        case $1 in
            --help|-h) show_upgrade_help ;;
            --distro)
                _require_value $# "$1" "${2:-}"
                UPGRADE_PASSTHROUGH_ARGS=$(_passthrough_add_pair "$UPGRADE_PASSTHROUGH_ARGS" "$1" "$2")
                shift 2
                ;;
            *)
                if _parse_upgrade_common_arg $# "$1" "${2:-}"; then
                    # Passthrough to remote nodes (skip --no-rollback, local only)
                    case "$1" in
                        --kubernetes-version|--skip-drain)
                            if [ "$_UPGRADE_ARG_SHIFT" -eq 2 ]; then
                                UPGRADE_PASSTHROUGH_ARGS=$(_passthrough_add_pair "$UPGRADE_PASSTHROUGH_ARGS" "$1" "$2")
                            else
                                UPGRADE_PASSTHROUGH_ARGS=$(_passthrough_add_flag "$UPGRADE_PASSTHROUGH_ARGS" "$1")
                            fi
                            ;;
                    esac
                    shift "$_UPGRADE_ARG_SHIFT"
                elif _parse_remote_ssh_args $# "$1" "${2:-}"; then
                    shift "$_REMOTE_SSH_SHIFT"
                else
                    log_error "Unknown upgrade option: $1"
                    show_upgrade_help 1
                fi
                ;;
        esac
    done
}

# Validate upgrade deploy arguments (reuses address validation patterns from validate_deploy_args)
validate_upgrade_deploy_args() {
    # --control-planes is required
    if [ -z "$DEPLOY_CONTROL_PLANES" ]; then
        log_error "--control-planes is required for upgrade"
        exit 1
    fi

    # --kubernetes-version is required
    if [ -z "$UPGRADE_TARGET_VERSION" ]; then
        log_error "--kubernetes-version is required for upgrade"
        exit 1
    fi

    _validate_remote_node_args
}

# === Runner ===

_upgrade_node_local_main() {
    _ensure_distro_detected
    upgrade_node_local
}

_run_upgrade() {
    _run_dual_mode upgrade \
        parse_upgrade_deploy_args validate_upgrade_deploy_args upgrade_dry_run upgrade_cluster \
        "Local upgrade" parse_upgrade_local_args upgrade_dry_run _upgrade_node_local_main \
        "$@"
}
