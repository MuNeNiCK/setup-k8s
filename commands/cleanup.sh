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
    rm -f /etc/default/kubelet
    rm -rf /etc/kubernetes
    rm -rf /etc/systemd/system/kubelet.service.d
}

# Reset Kubernetes cluster state
reset_kubernetes_cluster() {
    if command -v kubeadm >/dev/null 2>&1; then
        log_info "Resetting kubeadm cluster state..."
        if ! kubeadm reset -f; then
            log_error "kubeadm reset failed"
            return 1
        fi
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

# confirm_cleanup and check_docker_warning are defined in lib/validation.sh

# === Cleanup argument parsing (moved from lib/validation.sh) ===

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
                # shellcheck disable=SC2034 # used by lib/validation.sh
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

# === Cleanup confirmation (moved from lib/validation.sh) ===

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
