#!/bin/sh

# Cluster status module: show node role, service state, versions, and pod status.
# Read-only operations only — no root required. The exit status reflects
# the health of the node (see show_status_help).

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

Exit status:
  0  kubelet and the container runtime are running, and the API server
     answers (when a kubeconfig is available)
  1  kubelet, the container runtime, the API server, or etcd (wide) is not working
  2  Kubernetes is not set up on this node
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

# Print the service state; succeed when active.
_status_check_service() {
    local svc="$1"
    if _service_is_active "$svc"; then
        log_info "  $svc: active"
        return 0
    fi
    log_info "  $svc: inactive"
    return 1
}

# Kubernetes configuration directory (overridable for tests)
_STATUS_K8S_DIR="/etc/kubernetes"

# Value of a kube-controller-manager / kube-apiserver flag from its manifest.
# Usage: _status_manifest_flag <component> <flag>
_status_manifest_flag() {
    sed -n "s/^ *- --$2=//p" "${_STATUS_K8S_DIR}/manifests/$1.yaml" 2>/dev/null | head -n 1
}

# --- Main status logic (local mode) ---

status_local() {
    log_info "=== Kubernetes Node Status ==="

    # Node role
    local role="not set up"
    if [ -f "${_STATUS_K8S_DIR}/manifests/kube-apiserver.yaml" ]; then
        role="control-plane"
    elif [ -f "${_STATUS_K8S_DIR}/kubelet.conf" ]; then
        role="worker"
    fi
    log_info "Node role: ${role}"
    if [ "$role" = "not set up" ] && ! command -v kubeadm >/dev/null 2>&1; then
        log_info "Kubernetes is not installed on this node"
        return 2
    fi

    local problems=0

    # Service status: kubelet and the runtime this node uses
    log_info ""
    log_info "--- Service Status ---"
    _status_check_service kubelet || problems=$((problems + 1))
    local runtime_ok=false svc
    for svc in containerd crio; do
        if _status_check_service "$svc"; then runtime_ok=true; fi
    done
    if [ "$runtime_ok" = false ]; then
        log_warn "  No container runtime is running"
        problems=$((problems + 1))
    fi

    # Version information
    log_info ""
    log_info "--- Versions ---"
    local ver
    if command -v kubelet >/dev/null 2>&1; then
        ver=$(kubelet --version 2>/dev/null | awk '{print $2}') || ver="(error)"
        log_info "  kubelet: ${ver:-(error)}"
    else
        log_info "  kubelet: not installed"
    fi
    if command -v kubeadm >/dev/null 2>&1; then
        ver=$(kubeadm version -o short 2>/dev/null) || ver="(error)"
        log_info "  kubeadm: ${ver:-(error)}"
    else
        log_info "  kubeadm: not installed"
    fi
    if command -v kubectl >/dev/null 2>&1; then
        ver=$(kubectl version --client -o yaml 2>/dev/null | awk '/gitVersion:/{print $2}') || ver="(error)"
        log_info "  kubectl: ${ver:-(error)}"
    else
        log_info "  kubectl: not installed"
    fi

    # Cluster queries need a kubeconfig (admin.conf on control planes)
    local kc="${KUBECONFIG:-}"
    if [ -z "$kc" ] && [ -r "${_STATUS_K8S_DIR}/admin.conf" ]; then
        kc="${_STATUS_K8S_DIR}/admin.conf"
    fi
    if [ -z "$kc" ] || ! command -v kubectl >/dev/null 2>&1; then
        log_info ""
        if [ "$role" = "control-plane" ]; then
            log_warn "No kubeconfig available (set KUBECONFIG or run as root) — cannot check the API server"
            problems=$((problems + 1))
        else
            log_info "No kubeconfig on this node — skipping cluster queries"
        fi
    elif ! kubectl --kubeconfig="$kc" get --raw /readyz >/dev/null 2>&1; then
        log_info ""
        log_warn "The API server does not answer (kubeconfig: ${kc})"
        problems=$((problems + 1))
    else
        log_info ""
        log_info "--- Nodes ---"
        kubectl --kubeconfig="$kc" get nodes 2>&1 | while IFS= read -r line; do log_info "  $line"; done

        log_info ""
        log_info "--- Pods (kube-system) ---"
        kubectl --kubeconfig="$kc" get pods -n kube-system 2>&1 | while IFS= read -r line; do log_info "  $line"; done

        if [ "$STATUS_OUTPUT_FORMAT" = "wide" ]; then
            log_info ""
            log_info "--- Cluster Info (wide) ---"
            local api_server pod_cidr svc_cidr
            api_server=$(kubectl --kubeconfig="$kc" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null) || api_server=""
            log_info "  API server: ${api_server:-(unknown)}"
            pod_cidr=$(_status_manifest_flag kube-controller-manager cluster-cidr)
            svc_cidr=$(_status_manifest_flag kube-apiserver service-cluster-ip-range)
            if [ -z "$pod_cidr" ] && [ -z "$svc_cidr" ]; then
                pod_cidr=$(kubectl --kubeconfig="$kc" get node -o jsonpath='{.items[0].spec.podCIDR}' 2>/dev/null) || pod_cidr=""
            fi
            log_info "  Pod CIDR: ${pod_cidr:-(not set)}"
            log_info "  Service CIDR: ${svc_cidr:-(unknown; only shown on control-plane nodes)}"

            log_info ""
            log_info "--- etcd Health ---"
            local etcd_cid etcd_health
            if [ "$role" != "control-plane" ]; then
                log_info "  not a control-plane node"
            elif etcd_cid=$(_find_etcd_container 2>/dev/null); then
                if etcd_health=$(_etcdctl_exec "$etcd_cid" endpoint health 2>&1); then
                    log_info "  $etcd_health"
                else
                    log_warn "  etcd is not healthy: ${etcd_health}"
                    problems=$((problems + 1))
                fi
            else
                log_warn "  etcd container not found"
                problems=$((problems + 1))
            fi
        fi
    fi

    log_info ""
    if [ "$problems" -gt 0 ]; then
        log_warn "=== End of Status: ${problems} problem(s) ==="
        return 1
    fi
    log_info "=== End of Status: OK ==="
    return 0
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
