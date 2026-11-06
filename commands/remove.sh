#!/bin/sh

# Remove module: orchestrate node removal from a Kubernetes cluster via SSH

# Show dry-run removal plan
remove_dry_run() {
    log_info "=== Remove Dry-Run Plan ==="
    log_info ""

    _parse_node_address "$REMOVE_CONTROL_PLANES"
    log_info "Control-Plane (orchestrator): ${_NODE_USER}@${_NODE_HOST}"
    log_info ""

    local node_count
    node_count=$(_csv_count "$REMOVE_NODES")
    log_info "Nodes to Remove (${node_count}):"
    local _i=0
    while [ "$_i" -lt "$node_count" ]; do
        local node
        node=$(_csv_get "$REMOVE_NODES" "$_i")
        _parse_node_address "$node"
        log_info "  - ${_NODE_USER}@${_NODE_HOST}"
        _i=$((_i + 1))
    done
    log_info ""

    _log_ssh_settings
    log_info ""

    log_info "Orchestration Plan:"
    log_info "  1. Check SSH connectivity to all nodes"
    log_info "  2. For each target node:"
    _i=0
    while [ "$_i" -lt "$node_count" ]; do
        local node
        node=$(_csv_get "$REMOVE_NODES" "$_i")
        _parse_node_address "$node"
        log_info "     [${_NODE_HOST}]"
        log_info "       a. Resolve Kubernetes node name"
        log_info "       b. kubectl drain (from control-plane)"
        log_info "       c. kubectl delete node (from control-plane)"
        log_info "       d. kubeadm reset -f (on target node)"
        _i=$((_i + 1))
    done
    log_info "  3. Show summary"
    log_info ""
    log_info "=== End of dry-run (no changes made) ==="
}

# Confirmation prompt for remove
_confirm_remove() {
    local node_count
    node_count=$(_csv_count "$REMOVE_NODES")

    log_warn "The following ${node_count} node(s) will be removed from the cluster:"
    local _i=0
    while [ "$_i" -lt "$node_count" ]; do
        local node
        node=$(_csv_get "$REMOVE_NODES" "$_i")
        _parse_node_address "$node"
        log_warn "  - ${_NODE_USER}@${_NODE_HOST}"
        _i=$((_i + 1))
    done
    echo ""
    _confirm_destructive_action
}

# Main remove orchestration (remote mode)
remove_cluster() {
    local node_count
    node_count=$(_csv_count "$REMOVE_NODES")

    # Confirmation prompt
    _confirm_remove

    _audit_log "remove" "started" "nodes=${node_count}"
    log_info "Removing ${node_count} node(s) from the cluster"

    # Parse control-plane address
    _parse_node_address "$REMOVE_CONTROL_PLANES"
    local cp_user="$_NODE_USER" cp_host="$_NODE_HOST"
    local sudo_pfx; sudo_pfx=$(_sudo_prefix "$cp_user")

    local _step=0

    # --- Step 1: SSH connectivity check ---
    _step=$((_step + 1))
    log_info "Step ${_step}: Checking SSH connectivity..."
    if ! _init_remote_session "remove" "${REMOVE_CONTROL_PLANES},${REMOVE_NODES}"; then
        return 1
    fi

    # --- Step 2: Process each target node ---
    _step=$((_step + 1))
    log_info "Step ${_step}: Removing nodes..."
    local remove_failed=false
    local removed_nodes="" failed_nodes=""

    _i=0
    while [ "$_i" -lt "$node_count" ]; do
        local node
        node=$(_csv_get "$REMOVE_NODES" "$_i")
        _parse_node_address "$node"
        local node_user="$_NODE_USER" node_host="$_NODE_HOST"
        local node_sudo; node_sudo=$(_sudo_prefix "$node_user")

        log_info ""
        log_info "  [${node_host}] Processing node removal..."

        # a. Resolve Kubernetes node name
        local node_name
        node_name=$(_get_node_name "$cp_user" "$cp_host" "$node_host")
        if [ -z "$node_name" ]; then
            log_warn "  [${node_host}] Could not resolve node name, using host as node name"
            node_name="$node_host"
        fi
        log_info "  [${node_host}] Kubernetes node name: ${node_name}"

        # b. kubectl drain
        log_info "  [${node_host}] Draining node ${node_name}..."
        if ! _deploy_ssh "$cp_user" "$cp_host" "${sudo_pfx}kubectl --kubeconfig=/etc/kubernetes/admin.conf drain '${node_name}' --ignore-daemonsets --delete-emptydir-data --force --timeout=300s" 2>&1; then
            log_warn "  [${node_host}] Drain failed (node may already be drained or not ready). Continuing..."
        fi

        # c. kubectl delete node
        log_info "  [${node_host}] Deleting node ${node_name} from cluster..."
        if ! _deploy_ssh "$cp_user" "$cp_host" "${sudo_pfx}kubectl --kubeconfig=/etc/kubernetes/admin.conf delete node '${node_name}'" 2>&1; then
            log_warn "  [${node_host}] Delete node failed. Continuing with reset..."
        fi

        # d. kubeadm reset on target node
        log_info "  [${node_host}] Running kubeadm reset on target node..."
        if ! _deploy_ssh "$node_user" "$node_host" "${node_sudo}kubeadm reset -f" 2>&1; then
            log_error "  [${node_host}] kubeadm reset failed"
            remove_failed=true
            failed_nodes="${failed_nodes}${failed_nodes:+, }${node_host}"
            _i=$((_i + 1))
            continue
        fi

        log_info "  [${node_host}] Node removed successfully"
        removed_nodes="${removed_nodes}${removed_nodes:+, }${node_host}"
        _i=$((_i + 1))
    done

    # --- Post-remove health check ---
    _parse_node_address "$REMOVE_CONTROL_PLANES"
    log_info ""
    _health_check_cluster "$_NODE_USER" "$_NODE_HOST" --post || true

    # --- Step 3: Summary ---
    log_info ""
    log_info "=== Remove Summary ==="
    log_info ""
    _parse_node_address "$REMOVE_CONTROL_PLANES"
    log_info "Control-Plane: ${_NODE_USER}@${_NODE_HOST}"
    log_info ""
    if [ -n "$removed_nodes" ]; then
        log_info "Removed: ${removed_nodes}"
    fi
    if [ -n "$failed_nodes" ]; then
        log_error "Failed: ${failed_nodes}"
    fi
    log_info ""
    log_info "=========================="

    # Clean up known_hosts
    _teardown_session_known_hosts
    _pop_cleanup

    if [ "$remove_failed" = true ]; then
        _audit_log "remove" "failed" "failed=${failed_nodes}"
        log_error "Some node removals failed. Check logs above."
        return 1
    fi

    _audit_log "remove" "completed" "removed=${removed_nodes}"
    log_info "All nodes removed successfully!"
    return 0
}

# === Remove argument parsing ===

# Help message for remove
show_remove_help() {
    echo "Usage: $0 remove [options]"
    echo ""
    echo "Remove nodes from a Kubernetes cluster (drain, delete, reset)."
    echo ""
    echo "Required:"
    echo "  --control-planes IP       Control-plane node to run drain/delete from (user@ip or ip)"
    echo "  --workers IPs             Comma-separated list of nodes to remove (user@ip or ip)"
    echo ""
    echo "Optional:"
    echo "  --force                   Skip confirmation prompt"
    _show_common_ssh_help "  "
    _show_help_footer "  " "Show removal plan and exit"
    echo ""
    echo "Examples:"
    echo "  $0 remove --control-planes root@10.0.0.1 --workers root@10.0.0.2,root@10.0.0.3"
    echo "  $0 remove --control-planes 10.0.0.1 --workers 10.0.0.2 --force"
    exit "${1:-0}"
}

# Parse command line arguments for remove
parse_remove_args() {
    while [ $# -gt 0 ]; do
        case $1 in
            --help|-h)
                show_remove_help
                ;;
            --control-planes)
                _require_value $# "$1" "${2:-}"
                REMOVE_CONTROL_PLANES="$2"
                shift 2
                ;;
            --workers)
                _require_value $# "$1" "${2:-}"
                REMOVE_NODES="$2"
                shift 2
                ;;
            --force)
                # shellcheck disable=SC2034 # used by lib/core/validate.sh
                FORCE=true
                shift
                ;;
            *)
                if _is_common_ssh_flag "$1"; then
                    _parse_common_ssh_args $# "$1" "${2:-}"
                    shift "$_SSH_SHIFT"
                else
                    log_error "Unknown remove option: $1"
                    show_remove_help 1
                fi
                ;;
        esac
    done
}

# Validate remove arguments
validate_remove_args() {
    # --control-planes is required
    if [ -z "$REMOVE_CONTROL_PLANES" ]; then
        log_error "--control-planes is required for remove"
        exit 1
    fi

    # --workers is required
    if [ -z "$REMOVE_NODES" ]; then
        log_error "--workers is required for remove"
        exit 1
    fi

    # Normalize node list
    REMOVE_NODES=$(_normalize_node_list "$REMOVE_NODES")
    if [ -z "$REMOVE_NODES" ]; then
        log_error "--workers contains no valid node addresses"
        exit 1
    fi

    _validate_common_ssh_args

    # Validate all addresses (CP + nodes)
    local all_addrs="${REMOVE_CONTROL_PLANES},${REMOVE_NODES}"
    _validate_node_addresses "$all_addrs"

    # Safety: prevent removing the CP node itself
    local cp_host="${REMOVE_CONTROL_PLANES#*@}"
    _check_not_cp_self() {
        local node_host="${1#*@}"
        if [ "$node_host" = "$cp_host" ]; then
            log_error "Cannot remove the control-plane node itself (${cp_host}). Use 'cleanup' on the node instead."
            exit 1
        fi
    }
    _csv_for_each "$REMOVE_NODES" _check_not_cp_self
}

# === Runner ===

_run_remove() {
    _run_remote remove parse_remove_args validate_remove_args remove_dry_run remove_cluster "$@"
}
