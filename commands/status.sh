#!/bin/sh

# Cluster status module: show node role, service state, versions, and pod status.
# Read-only operations only — no root required.

# --- Help ---

show_status_help() {
    cat <<'EOF'
Usage: setup-k8s.sh status [options]

Show the current status of this Kubernetes node and cluster.

Options:
  --output FORMAT   Output format: text (default) or wide
  --dry-run         Show what checks would be performed
  --help, -h        Display this help message

Output (text mode):
  - Node role (control-plane / worker)
  - Service status (kubelet, containerd, crio)
  - Installed versions (kubelet, kubeadm, kubectl)
  - kubectl get nodes (if configured)
  - kubectl get pods -n kube-system (if configured)

Output (wide mode, additionally):
  - Cluster info (API server endpoint, Pod/Service CIDR)
  - etcd health check
EOF
    exit "${1:-0}"
}

# --- Argument parsing ---

parse_status_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --output)
                _require_value $# "$1" "${2:-}"
                STATUS_OUTPUT_FORMAT="$2"
                case "$STATUS_OUTPUT_FORMAT" in
                    text|wide) ;;
                    *)
                        log_error "Invalid --output format '$STATUS_OUTPUT_FORMAT'. Valid: text, wide"
                        exit 1
                        ;;
                esac
                shift 2
                ;;
            --help|-h)
                show_status_help
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
}

# --- Service status helper ---

_status_check_service() {
    local svc="$1"
    if _service_is_active "$svc"; then
        log_info "  $svc: active"
    else
        log_info "  $svc: inactive"
    fi
}

# --- Main status logic (local mode) ---

status_local() {
    log_info "=== Kubernetes Node Status ==="

    # Node role detection
    if [ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]; then
        log_info "Node role: control-plane"
    else
        log_info "Node role: worker"
    fi

    # Service status
    log_info ""
    log_info "--- Service Status ---"
    _status_check_service "kubelet"
    _status_check_service "containerd"
    _status_check_service "crio"

    # Version information
    log_info ""
    log_info "--- Versions ---"
    local ver
    if command -v kubelet >/dev/null 2>&1; then
        ver=$(kubelet --version 2>/dev/null | awk '{print $2}') || ver="(error)"
        log_info "  kubelet: $ver"
    else
        log_info "  kubelet: not installed"
    fi
    if command -v kubeadm >/dev/null 2>&1; then
        ver=$(kubeadm version -o short 2>/dev/null) || ver="(error)"
        log_info "  kubeadm: $ver"
    else
        log_info "  kubeadm: not installed"
    fi
    if command -v kubectl >/dev/null 2>&1; then
        ver=$(kubectl version --client -o yaml 2>/dev/null | awk '/gitVersion:/{print $2}') || ver="(error)"
        log_info "  kubectl: $ver"
    else
        log_info "  kubectl: not installed"
    fi

    # kubectl-based checks (skip gracefully if not configured)
    if command -v kubectl >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then
        log_info ""
        log_info "--- Nodes ---"
        kubectl get nodes 2>&1 | while IFS= read -r line; do log_info "  $line"; done

        log_info ""
        log_info "--- Pods (kube-system) ---"
        kubectl get pods -n kube-system 2>&1 | while IFS= read -r line; do log_info "  $line"; done

        # Wide mode: additional cluster info
        if [ "$STATUS_OUTPUT_FORMAT" = "wide" ]; then
            log_info ""
            log_info "--- Cluster Info (wide) ---"

            # API server endpoint
            local api_server
            api_server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null) || api_server="(unknown)"
            log_info "  API server: $api_server"

            # Pod CIDR
            local pod_cidr
            pod_cidr=$(kubectl cluster-info dump 2>/dev/null | grep -m1 '"cluster-cidr"' | sed 's/.*"cluster-cidr=\([^"]*\)".*/\1/') || pod_cidr="(unknown)"
            log_info "  Pod CIDR: $pod_cidr"

            # Service CIDR
            local svc_cidr
            svc_cidr=$(kubectl cluster-info dump 2>/dev/null | grep -m1 '"service-cluster-ip-range"' | sed 's/.*"service-cluster-ip-range=\([^"]*\)".*/\1/') || svc_cidr="(unknown)"
            log_info "  Service CIDR: $svc_cidr"

            # etcd health (requires root typically, but try)
            log_info ""
            log_info "--- etcd Health ---"
            local etcd_cid
            if etcd_cid=$(_find_etcd_container 2>/dev/null); then
                local etcd_health
                etcd_health=$(_etcdctl_exec "$etcd_cid" endpoint health 2>&1) || etcd_health="(error checking health)"
                log_info "  $etcd_health"
            else
                log_info "  etcd container not found (not a control-plane node or not running)"
            fi
        fi
    else
        log_info ""
        log_warn "kubectl not configured or cluster unreachable — skipping cluster queries"
    fi

    log_info ""
    log_info "=== End of Status ==="
}

# --- Dry-run ---

status_dry_run() {
    log_info "=== Dry-run: Status Checks ==="
    log_info "Output format: $STATUS_OUTPUT_FORMAT"
    log_info "Checks to perform:"
    log_info "  1. Node role detection (/etc/kubernetes/manifests/kube-apiserver.yaml)"
    log_info "  2. Service status (kubelet, containerd, crio)"
    log_info "  3. Version info (kubelet, kubeadm, kubectl)"
    log_info "  4. kubectl get nodes"
    log_info "  5. kubectl get pods -n kube-system"
    if [ "$STATUS_OUTPUT_FORMAT" = "wide" ]; then
        log_info "  6. Cluster info (API server, Pod/Service CIDR)"
        log_info "  7. etcd endpoint health"
    fi
    log_info "=== End of dry-run (no changes made) ==="
}

# === Runner ===

_run_status() {
    parse_status_args "$@"
    _dry_run_guard status_dry_run
    status_local
    exit $?
}
