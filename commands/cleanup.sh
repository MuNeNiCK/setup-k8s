#!/bin/sh

# === Cleanup (cleanup subcommand) ===

# Clean up .kube directories
cleanup_kube_configs() {
    # Clean up .kube directory
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        local USER_HOME
        USER_HOME=$(get_user_home "$SUDO_USER")
        log_info "Cleanup: Removing .kube directory and config for user $SUDO_USER"
        rm -f "$USER_HOME/.kube/config"
        rmdir "$USER_HOME/.kube" 2>/dev/null || true
    fi

    # Clean up root's .kube directory
    local ROOT_HOME
    ROOT_HOME=$(get_user_home root)
    log_info "Cleanup: Removing .kube directory and config for root user at $ROOT_HOME"
    rm -f "$ROOT_HOME/.kube/config"
    rmdir "$ROOT_HOME/.kube" 2>/dev/null || true
}

# Reset containerd configuration
reset_containerd_config() {
    if [ -f /etc/containerd/config.toml ]; then
        log_info "Resetting containerd configuration to default..."
        if command -v containerd >/dev/null 2>&1; then
            # Backup current config
            if ! cp /etc/containerd/config.toml "/etc/containerd/config.toml.bak.$(date +%Y%m%d%H%M%S)"; then
                log_warn "Failed to backup containerd config"
                return 1
            fi
            # Generate default config
            if ! containerd config default > /etc/containerd/config.toml; then
                log_warn "Failed to generate default containerd config"
                return 1
            fi
            # Restart containerd if it's running
            if _service_is_active containerd; then
                log_info "Restarting containerd with default configuration..."
                _service_restart containerd
            fi
        fi
    fi
}

# Stop Kubernetes services
stop_kubernetes_services() {
    log_info "Stopping Kubernetes services..."
    _service_stop kubelet
    _service_disable kubelet
    # Verify kubelet is actually stopped
    if _service_is_active kubelet; then
        log_error "kubelet is still active after stop attempt"
        return 1
    fi
}

# Stop CRI services
stop_cri_services() {
    log_info "Checking and stopping CRI services..."

    # Stop CRI-O if present
    local _crio_found=false
    case "$(_detect_init_system)" in
        systemd) systemctl list-unit-files 2>/dev/null | grep -q '^crio\.service' && _crio_found=true ;;
        openrc)  [ -f /etc/init.d/crio ] && _crio_found=true ;;
    esac
    if [ "$_crio_found" = true ]; then
        log_info "Stopping and disabling CRI-O service..."
        _service_stop crio
        _service_disable crio
        if _service_is_active crio; then
            log_warn "CRI-O is still active after stop attempt"
            return 1
        fi
    fi

    # Note: containerd is not stopped to avoid impacting Docker
    # Only its configuration will be reset later with reset_containerd_config()
}

# Remove Kubernetes configuration files
remove_kubernetes_configs() {
    log_info "Removing Kubernetes configuration files..."
    rm -f /etc/default/kubelet /etc/sysconfig/kubelet
    rm -rf /etc/kubernetes
    rm -rf /etc/systemd/system/kubelet.service.d
}

# Remove installed components (packages, repositories, binaries) and host
# preparation artifacts, then verify that nothing is left.
cleanup_installed_components() {
    local rc=0
    k8s_remove || rc=1
    crio_remove || rc=1
    containerd_cleanup || rc=1
    if [ "${DISTRO_K8S_SOURCE:-}" = binary ] && [ "$PRESERVE_CNI" = false ] && [ -d /opt/cni/bin ]; then
        rm -rf /opt/cni/bin
        log_info "Removed /opt/cni/bin/"
    fi
    system_cleanup
    proxy_cleanup
    _service_reload

    local left
    left=$(_cleanup_leftovers)
    log_info "Verifying cleanup..."
    if [ -n "$left" ]; then
        printf '%s\n' "$left" | while IFS= read -r item; do log_warn "  Still present: ${item}"; done
        log_warn "Some components could not be removed. You may want to remove them manually."
        return 1
    fi
    log_info "No Kubernetes packages, binaries, package locks, repositories, or configuration remain."
    return "$rc"
}

# Configuration roots checked by _cleanup_leftovers (overridable for tests)
_CLEANUP_ETC="/etc"
# kube-vip static pod manifest (names the VIP to release)
_CLEANUP_KUBE_VIP_MANIFEST="/etc/kubernetes/manifests/kube-vip.yaml"

# Print what setup-k8s installs or configures and is still present, one item
# per line. Uses its own checks (PATH lookups, package database queries,
# lock lists, file names) rather than the result of the removal steps.
_cleanup_leftovers() {
    local name file
    hash -r 2>/dev/null || true
    if command -v pgrep >/dev/null 2>&1; then
        for name in kubelet kube-apiserver kube-controller-manager kube-scheduler etcd kube-proxy kube-vip; do
            if pgrep -x "$name" >/dev/null 2>&1; then echo "process ${name}"; fi
        done
    fi
    for name in kubeadm kubelet kubectl crio; do
        if command -v "$name" >/dev/null 2>&1; then
            echo "binary $(command -v "$name")"
        fi
    done
    if [ -n "${DISTRO_PKG:-}" ]; then
        # shellcheck disable=SC2046 # space-separated package names
        for name in $(printf '%s\n' kubeadm kubelet kubectl cri-tools kubernetes-cni cri-o $(k8s_distro_installed_pkgs) | awk '!seen[$0]++'); do
            if pkg_installed "$name"; then echo "package ${name}"; fi
        done
    fi
    if _crio_selinux_module_loaded; then echo "selinux-module ${_CRIO_SELINUX_MODULE}"; fi
    if command -v apt-mark >/dev/null 2>&1; then
        apt-mark showhold 2>/dev/null | grep -E '^(kube|cri-tools$|cri-o$)' | sed 's/^/hold /'
    fi
    if command -v dnf >/dev/null 2>&1 && dnf versionlock list >/dev/null 2>&1; then
        dnf versionlock list 2>/dev/null | grep -o -E '(kubeadm|kubelet|kubectl|cri-tools|cri-o)' | sort -u | sed 's/^/versionlock /'
    fi
    if command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive locks 2>/dev/null | grep -o -E '\b(kubeadm|kubelet|kubectl|cri-tools|cri-o)\b' | sort -u | sed 's/^/lock /'
    fi
    for file in apt/sources.list.d/kubernetes.list apt/sources.list.d/cri-o.list apt/sources.list.d/docker.list \
                apt/keyrings/kubernetes.gpg apt/keyrings/cri-o.gpg apt/keyrings/docker.gpg \
                apt/keyrings/kubernetes-apt-keyring.gpg apt/keyrings/crio-apt-keyring.gpg \
                yum.repos.d/kubernetes.repo yum.repos.d/cri-o.repo yum.repos.d/docker.repo \
                yum.repos.d/docker-ce.repo yum.repos.d/containers.repo \
                zypp/repos.d/kubernetes.repo zypp/repos.d/cri-o.repo zypp/repos.d/containers.repo \
                default/kubelet sysconfig/kubelet systemd/system/kubelet.service init.d/kubelet \
                systemd/system/containerd.service.d/10-setup-k8s-proxy.conf systemd/system/crio.service.d/10-setup-k8s-proxy.conf; do
        if [ -e "${_CLEANUP_ETC}/${file}" ]; then echo "file ${_CLEANUP_ETC}/${file}"; fi
    done
    for file in kubernetes systemd/system/kubelet.service.d; do
        if [ -d "${_CLEANUP_ETC}/${file}" ]; then echo "directory ${_CLEANUP_ETC}/${file}"; fi
    done
}

# Reset Kubernetes cluster state
reset_kubernetes_cluster() {
    # kubeadm reset deletes the kube-vip manifest, which names the VIP; the VIP
    # is released after the reset has removed the kube-vip container (a
    # running kube-vip leader assigns it again)
    local vip_manifest=""
    if [ -f "$_CLEANUP_KUBE_VIP_MANIFEST" ]; then
        vip_manifest=$(mktemp)
        cp "$_CLEANUP_KUBE_VIP_MANIFEST" "$vip_manifest"
    fi
    if command -v kubeadm >/dev/null 2>&1; then
        log_info "Resetting kubeadm cluster state..."
        if ! kubeadm reset -f; then
            log_error "kubeadm reset failed"
            rm -f "$vip_manifest"
            return 1
        fi
    fi
    if [ -n "$vip_manifest" ]; then
        if ! kube_vip_release "$vip_manifest"; then
            rm -f "$vip_manifest"
            return 1
        fi
        rm -f "$vip_manifest"
    fi
}

# Conditionally cleanup CNI
cleanup_cni_conditionally() {
    if [ "$PRESERVE_CNI" = false ]; then
        cleanup_cni
    else
        log_info "Preserving CNI configurations as requested."
    fi
}

# Show cleanup plan without making changes.
cleanup_dry_run() {
    log_info "=== Cleanup Dry-Run Plan ==="
    log_info ""
    log_info "Distribution: ${DISTRO_NAME:-unknown} (family: ${DISTRO_FAMILY:-unknown})"
    log_info ""
    log_info "The following operations would be performed:"
    log_info "  1. Stop kubelet and kube-proxy services"
    log_info "  2. Stop container runtime services (containerd/crio)"
    log_info "  3. Run kubeadm reset -f"
    log_info "  4. Remove Kubernetes config files (/etc/kubernetes/)"
    log_info "  5. Restore swap (fstab and zram)"
    if [ "${PRESERVE_CNI:-false}" = true ]; then
        log_info "  6. CNI: preserved (--preserve-cni)"
    else
        log_info "  6. Remove CNI configurations (/etc/cni/, /opt/cni/)"
    fi
    log_info "  7. Remove network configurations (calico, flannel, etc.)"
    log_info "  8. Remove kube configs (~/.kube/)"
    log_info "  9. Remove crictl config"
    log_info " 10. Reset iptables rules"
    log_info " 11. Reset containerd configuration"
    log_info " 12. Reload systemd daemon"
    log_info " 13. Distribution-specific cleanup"
    log_info " 14. Remove shell completions (kubectl, kubeadm, crictl)"
    local optional_step=15
    if [ "${REMOVE_HELM:-false}" = true ]; then
        log_info " ${optional_step}. Remove Helm binary and configuration (--remove-helm)"
        optional_step=$((optional_step + 1))
    fi
    if [ "${REMOVE_KUSTOMIZE:-false}" = true ]; then
        log_info " ${optional_step}. Remove Kustomize binary and configuration (--remove-kustomize)"
    fi
    log_info ""
    log_info "=== End of dry-run (no changes made) ==="
}


# === Cleanup argument parsing ===

# Help message for cleanup
show_cleanup_help() {
    echo "Usage: sudo $0 cleanup [options]"
    echo ""
    echo "Clean up Kubernetes installation from this node."
    echo ""
    echo "Options:"
    echo "  --force                 Skip confirmation prompt"
    echo "  --preserve-cni          Preserve CNI configurations"
    echo "  --remove-helm           Remove Helm binary and configuration"
    echo "  --remove-kustomize      Remove Kustomize binary and configuration"
    echo "  --distro FAMILY         Override distro family detection (debian, rhel, suse, arch, alpine, generic)"
    _show_help_footer "  " "Show cleanup plan and exit"
    exit "${1:-0}"
}

# Parse command line arguments for cleanup
parse_cleanup_args() {
    while [ $# -gt 0 ]; do
        case $1 in
            --force)
                # shellcheck disable=SC2034 # used by lib/core/validate.sh
                FORCE=true
                shift
                ;;
            --preserve-cni)
                # shellcheck disable=SC2034 # used by helpers.sh
                PRESERVE_CNI=true
                shift
                ;;
            --remove-helm)
                # shellcheck disable=SC2034 # used by setup-k8s.sh cleanup subcommand
                REMOVE_HELM=true
                shift
                ;;
            --remove-kustomize)
                # shellcheck disable=SC2034 # used by setup-k8s.sh cleanup subcommand
                REMOVE_KUSTOMIZE=true
                shift
                ;;
            *)
                if _is_distro_flag "$1"; then
                    _parse_distro_flag $# "$1" "${2:-}"
                    shift "$_DISTRO_SHIFT"
                else
                    log_error "Unknown option: $1"
                    log_error "Run with --help for usage information"
                    exit 1
                fi
                ;;
        esac
    done
}

# === Cleanup confirmation ===

# Confirmation prompt for cleanup
confirm_cleanup() {
    log_warn "This script will remove Kubernetes configurations."
    _confirm_destructive_action
}

# Check if Docker is installed and warn about containerd
check_docker_warning() {
    if command -v docker >/dev/null 2>&1; then
        log_warn "Docker is installed on this system."
        log_warn "This cleanup script will reset containerd configuration but will NOT remove containerd."
        log_warn "Docker should continue to work normally after cleanup."
    fi
}

# === Runner ===

_run_cleanup() {
    _require_root "Cleanup"
    parse_cleanup_args "$@"
    _ensure_distro_detected
    _dry_run_guard cleanup_dry_run
    confirm_cleanup
    _audit_start cleanup

    CLEANUP_ERRORS=0
    log_info "Starting Kubernetes cleanup..."
    check_docker_warning
    stop_kubernetes_services || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
    # kubeadm reset removes the pod containers through the runtime, so the
    # runtime must still run (CRI-O containers outlive a stopped CRI-O)
    reset_kubernetes_cluster || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
    stop_cri_services || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
    remove_kubernetes_configs || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
    restore_fstab_swap || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
    restore_zram_swap || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
    cleanup_cni_conditionally || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
    cleanup_network_configs || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
    cleanup_kube_configs || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
    cleanup_crictl_config || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
    reset_iptables || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
    reset_containerd_config || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
    _service_reload || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
    cleanup_installed_components || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
    cleanup_kubernetes_completions || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
    if [ "${REMOVE_HELM:-false}" = true ]; then
        cleanup_helm || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
    fi
    if [ "${REMOVE_KUSTOMIZE:-false}" = true ]; then
        cleanup_kustomize || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
    fi

    if [ "$CLEANUP_ERRORS" -gt 0 ]; then
        log_error "Cleanup finished with $CLEANUP_ERRORS error(s). Check the output above for details."
        exit 1
    fi
    _audit_done
    log_info "Cleanup complete! Please reboot the system for all changes to take effect."
    exit 0
}
