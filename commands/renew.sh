#!/bin/sh

# Certificate renewal module: renew or check kubeadm-managed certificates.
# Wraps `kubeadm certs renew` and `kubeadm certs check-expiration`.
#
# === Sections ===
# 1. Certificate validation helpers         (~line 8)
# 2. Local renewal (renew_certs_local)       (~line 55)
# 3. Dry-run display                        (~line 172)
# 4. Remote orchestration (renew_cluster)    (~line 218)
# 5. CLI parsing & help                     (~line 288)

# Valid certificate names for kubeadm certs renew
_VALID_CERT_NAMES="apiserver apiserver-kubelet-client front-proxy-client apiserver-etcd-client etcd-healthcheck-client etcd-peer etcd-server admin.conf controller-manager.conf scheduler.conf super-admin.conf"

# Validate certificate names in RENEW_CERTS.
# Usage: _validate_cert_names
_validate_single_cert_name() {
    local cert_name="$1"
    local valid=false
    for known in $_VALID_CERT_NAMES; do
        if [ "$cert_name" = "$known" ]; then
            valid=true
            break
        fi
    done
    if [ "$valid" = false ]; then
        log_error "Unknown certificate name: '$cert_name'"
        log_error "Valid names: $_VALID_CERT_NAMES"
        return 1
    fi
}

_validate_cert_names() {
    if [ "$RENEW_CERTS" = "all" ]; then
        return 0
    fi
    _csv_for_each "$RENEW_CERTS" _validate_single_cert_name
}

# Check if any etcd certificates are included in the renewal set.
# Returns 0 if etcd certs are present, 1 otherwise.
_has_etcd_certs() {
    if [ "$RENEW_CERTS" = "all" ]; then
        return 0
    fi
    _is_etcd_cert() {
        case "$1" in
            etcd-*|apiserver-etcd-client) return 0 ;;
            *) return 1 ;;
        esac
    }
    _csv_any "$RENEW_CERTS" _is_etcd_cert
}

# Restart control-plane static pod components after certificate renewal.
# kubelet watches manifests and restarts pods, but crictl stop forces immediate restart.
_restart_control_plane_components() {
    log_info "Restarting control-plane components..."

    if ! command -v crictl >/dev/null 2>&1; then
        log_warn "crictl not found, skipping component restart"
        log_warn "Restart kubelet manually: systemctl restart kubelet"
        return 0
    fi

    local components="kube-apiserver kube-controller-manager kube-scheduler"
    if _has_etcd_certs; then
        components="$components etcd"
    fi

    for component in $components; do
        local cid
        cid=$(crictl ps --name="$component" --state=running -q 2>/dev/null | head -1) || true
        if [ -n "$cid" ]; then
            log_info "  Restarting $component (container $cid)..."
            crictl stop "$cid" >/dev/null 2>&1 || true
        else
            log_debug "  $component container not found (may not be running)"
        fi
    done

    # Wait for API server to become ready
    log_info "Waiting for API server to become ready..."
    local elapsed=0 timeout=120
    while [ "$elapsed" -lt "$timeout" ]; do
        if kubectl get --raw /readyz >/dev/null 2>&1; then
            log_info "API server is ready"
            return 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done

    log_warn "API server did not become ready within ${timeout}s (may still be starting)"
    return 0
}

# --- Local renewal ---

renew_certs_local() {
    _audit_log "renew" "started" "certs=${RENEW_CERTS} check_only=${RENEW_CHECK_ONLY}"
    log_info "Starting certificate renewal..."

    # Verify this is a control-plane node
    if [ ! -f /etc/kubernetes/manifests/kube-apiserver.yaml ]; then
        log_error "This node does not appear to be a control-plane node"
        log_error "  (missing /etc/kubernetes/manifests/kube-apiserver.yaml)"
        _audit_log "renew" "failed" "reason=not_control_plane_node"
        return 1
    fi

    # Validate certificate names
    if ! _validate_cert_names; then
        _audit_log "renew" "failed" "reason=invalid_cert_names"
        return 1
    fi

    # Show current certificate expiration
    log_info "Current certificate expiration:"
    kubeadm certs check-expiration 2>&1 | while IFS= read -r line; do
        log_info "  $line"
    done

    # If check-only mode, stop here
    if [ "$RENEW_CHECK_ONLY" = true ]; then
        log_info "Check-only mode: no certificates were renewed"
        return 0
    fi

    # Renew certificates
    if [ "$RENEW_CERTS" = "all" ]; then
        log_info "Renewing all certificates..."
        if ! kubeadm certs renew all; then
            log_error "Certificate renewal failed"
            _audit_log "renew" "failed" "reason=kubeadm_renew_all_failed"
            return 1
        fi
    else
        _renew_single_cert() {
            log_info "Renewing certificate: $1..."
            if ! kubeadm certs renew "$1"; then
                log_error "Failed to renew certificate: $1"
                _audit_log "renew" "failed" "reason=kubeadm_renew_failed cert=$1"
                return 1
            fi
        }
        _csv_for_each "$RENEW_CERTS" _renew_single_cert || return 1
    fi

    # Restart control-plane components
    _restart_control_plane_components

    # Show updated certificate expiration
    log_info ""
    log_info "Updated certificate expiration:"
    kubeadm certs check-expiration 2>&1 | while IFS= read -r line; do
        log_info "  $line"
    done

    _audit_log "renew" "completed" "certs=${RENEW_CERTS}"
    log_info "Certificate renewal complete!"
    return 0
}

# --- Dry-run ---

renew_dry_run() {
    log_info "=== Renew Dry-Run Plan ==="
    log_info ""

    if [ -n "$DEPLOY_CONTROL_PLANES" ]; then
        log_info "Mode: Remote"
        log_info "Control-plane nodes: $DEPLOY_CONTROL_PLANES"
        log_info ""
        _log_ssh_settings
        log_info ""
        log_info "Certificates: $RENEW_CERTS"
        if [ "$RENEW_CHECK_ONLY" = true ]; then
            log_info "Action: Check expiration only (no renewal)"
        else
            log_info "Action: Renew certificates"
        fi
        log_info ""
        log_info "Orchestration Plan:"
        log_info "  1. Check SSH connectivity to all nodes"
        log_info "  2. Generate and transfer bundle"
        log_info "  3. Execute renewal on each node sequentially"
        log_info "  4. Display summary"
    else
        log_info "Mode: Local"
        log_info "Certificates: $RENEW_CERTS"
        if [ "$RENEW_CHECK_ONLY" = true ]; then
            log_info "Action: Check expiration only (no renewal)"
        else
            log_info "Action: Renew certificates"
        fi
        log_info ""
        log_info "Steps:"
        log_info "  1. Verify control-plane node"
        log_info "  2. Show current certificate expiration"
        if [ "$RENEW_CHECK_ONLY" != true ]; then
            log_info "  3. Renew certificates via kubeadm"
            log_info "  4. Restart control-plane components"
            log_info "  5. Show updated certificate expiration"
        fi
    fi
    log_info ""
    log_info "=== End of dry-run (no changes made) ==="
}

# --- Remote orchestration ---

renew_cluster() {
    local cp_count
    cp_count=$(_csv_count "$DEPLOY_CONTROL_PLANES")
    log_info "Starting remote certificate renewal on $cp_count control-plane node(s)..."
    log_info "Certificates: $RENEW_CERTS"
    if [ "$RENEW_CHECK_ONLY" = true ]; then
        log_info "Mode: check-only"
    fi
    log_info ""

    # Step 1: Check SSH connectivity to all nodes
    log_info "Step 1: Checking SSH connectivity..."
    if ! remote_session_open "renew" "$DEPLOY_CONTROL_PLANES"; then
        return 1
    fi

    # Step 2: Transfer bundle and execute on each node sequentially
    log_info "Step 2: Renewing certificates on each node sequentially..."
    local success_count=0 fail_count=0

    _i=0
    _old_ifs="$IFS"; IFS=','
    for node in $DEPLOY_CONTROL_PLANES; do
        IFS="$_old_ifs"
        _i=$((_i + 1))
        _parse_node_address "$node"
        log_info ""
        log_info "--- Node $_i/$cp_count: ${_NODE_HOST} ---"

        if remote_run --forward "$RENEW_PASSTHROUGH_ARGS" "$node" "cert renew" renew; then
            success_count=$((success_count + 1))
        else
            log_error "Certificate renewal failed on ${_NODE_HOST}"
            fail_count=$((fail_count + 1))
        fi
        IFS=','
    done
    IFS="$_old_ifs"

    remote_session_close

    # Summary
    log_info ""
    log_info "=== Certificate Renewal Summary ==="
    log_info "  Total nodes: $cp_count"
    log_info "  Succeeded: $success_count"
    if [ "$fail_count" -gt 0 ]; then
        log_error "  Failed: $fail_count"
        return 1
    else
        log_info "  Failed: 0"
    fi
    log_info "Certificate renewal complete!"
    return 0
}

# === Renew argument parsing ===

# Help message for renew
show_renew_help() {
    echo "Usage: $0 renew [options]"
    echo ""
    echo "Renew or check Kubernetes certificates on control-plane nodes."
    echo ""
    echo "Local mode (run on a control-plane node with sudo):"
    echo "  Optional:"
    echo "    --certs CERTS             Certificates to renew: 'all' or comma-separated list. Default: all"
    echo "    --check-only              Only check certificate expiration (no renewal)"
    echo "    --distro FAMILY           Override distro family detection"
    _show_help_footer "    " "Show renewal plan and exit"
    echo ""
    echo "Remote mode (from local machine via SSH):"
    echo "  Required:"
    echo "    --control-planes IPs      Comma-separated control-plane nodes (user@ip or ip)"
    echo ""
    echo "  Optional:"
    echo "    --certs CERTS             Certificates to renew: 'all' or comma-separated list. Default: all"
    echo "    --check-only              Only check certificate expiration (no renewal)"
    _show_common_ssh_help "    "
    _show_help_footer "    " "Show renewal plan and exit"
    echo ""
    echo "Valid certificate names:"
    echo "  apiserver, apiserver-kubelet-client, front-proxy-client,"
    echo "  apiserver-etcd-client, etcd-healthcheck-client, etcd-peer,"
    echo "  etcd-server, admin.conf, controller-manager.conf,"
    echo "  scheduler.conf, super-admin.conf"
    echo ""
    echo "Examples:"
    echo "  # Local: check expiration only"
    echo "  sudo $0 renew --check-only"
    echo ""
    echo "  # Local: renew all certificates"
    echo "  sudo $0 renew"
    echo ""
    echo "  # Local: renew specific certificates"
    echo "  sudo $0 renew --certs apiserver,apiserver-kubelet-client"
    echo ""
    echo "  # Remote: renew all certificates on multiple control-plane nodes"
    echo "  $0 renew --control-planes 10.0.0.1,10.0.0.2 --ssh-key ~/.ssh/id_rsa"
    exit "${1:-0}"
}

# Parse a single renew-specific option common to local and deploy modes.
# Sets _RENEW_ARG_SHIFT. Returns 0 if handled, 1 if not.
_RENEW_ARG_SHIFT=0
_parse_renew_common_arg() {
    local argc=$1 arg="$2" next="${3:-}"
    _RENEW_ARG_SHIFT=0
    case "$arg" in
        --certs)
            _require_value "$argc" "$arg" "$next"
            RENEW_CERTS="$next"
            _RENEW_ARG_SHIFT=2
            ;;
        --check-only)
            RENEW_CHECK_ONLY=true
            _RENEW_ARG_SHIFT=1
            ;;
        *) return 1 ;;
    esac
}

# Parse command line arguments for renew (local mode)
parse_renew_local_args() {
    while [ $# -gt 0 ]; do
        case $1 in
            --help|-h) show_renew_help ;;
            *)
                if _parse_renew_common_arg $# "$1" "${2:-}"; then
                    shift "$_RENEW_ARG_SHIFT"
                elif _is_distro_flag "$1"; then
                    _parse_distro_flag $# "$1" "${2:-}"
                    shift "$_DISTRO_SHIFT"
                else
                    log_error "Unknown renew option: $1"
                    show_renew_help 1
                fi
                ;;
        esac
    done
}

# Parse command line arguments for renew (remote/deploy mode)
parse_renew_deploy_args() {
    while [ $# -gt 0 ]; do
        case $1 in
            --help|-h) show_renew_help ;;
            --distro)
                _require_value $# "$1" "${2:-}"
                RENEW_PASSTHROUGH_ARGS=$(_passthrough_add_pair "$RENEW_PASSTHROUGH_ARGS" "$1" "$2")
                shift 2
                ;;
            *)
                if _parse_renew_common_arg $# "$1" "${2:-}"; then
                    # Add passthrough for deploy mode
                    if [ "$_RENEW_ARG_SHIFT" -eq 2 ]; then
                        RENEW_PASSTHROUGH_ARGS=$(_passthrough_add_pair "$RENEW_PASSTHROUGH_ARGS" "$1" "$2")
                    else
                        RENEW_PASSTHROUGH_ARGS=$(_passthrough_add_flag "$RENEW_PASSTHROUGH_ARGS" "$1")
                    fi
                    shift "$_RENEW_ARG_SHIFT"
                elif _parse_remote_ssh_args $# "$1" "${2:-}"; then
                    shift "$_REMOTE_SSH_SHIFT"
                else
                    log_error "Unknown renew option: $1"
                    show_renew_help 1
                fi
                ;;
        esac
    done
}

# Validate renew deploy arguments
validate_renew_deploy_args() {
    # --control-planes is required
    if [ -z "$DEPLOY_CONTROL_PLANES" ]; then
        log_error "--control-planes is required for remote renew"
        exit 1
    fi

    _validate_remote_node_args
}

# === Runner ===

_run_renew() {
    _run_dual_mode renew \
        parse_renew_deploy_args validate_renew_deploy_args renew_dry_run renew_cluster \
        "Local certificate renewal" parse_renew_local_args renew_dry_run renew_certs_local \
        "$@"
}
