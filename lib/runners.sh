#!/bin/sh

# Subcommand runner functions for setup-k8s.sh.
# Each _run_* function parses arguments, validates them, handles --dry-run,
# and executes its subcommand. All modules are already loaded.

# Show dry-run configuration summary for init/join
_setup_dry_run() {
    log_info "=== Dry-run Configuration Summary ==="
    log_info "Action: ${ACTION}"
    log_info "Container Runtime: ${CRI}"
    log_info "Proxy mode: ${PROXY_MODE}"
    log_info "Kubernetes Version (minor): ${K8S_VERSION}"
    log_info "Distribution: ${DISTRO_NAME:-unknown} (family: ${DISTRO_FAMILY:-unknown})"
    log_info "Swap enabled: ${SWAP_ENABLED}"
    log_info "Install Helm: ${INSTALL_HELM}"
    log_info "Install Kustomize: ${INSTALL_KUSTOMIZE}"
    log_info "Shell Completion: ${ENABLE_COMPLETION} (shells: ${COMPLETION_SHELLS})"
    [ -n "$KUBEADM_POD_CIDR" ] && log_info "Pod network CIDR: $KUBEADM_POD_CIDR"
    [ -n "$KUBEADM_SERVICE_CIDR" ] && log_info "Service CIDR: $KUBEADM_SERVICE_CIDR"
    [ -n "$KUBEADM_API_ADDR" ] && log_info "API server address: $KUBEADM_API_ADDR"
    [ -n "$KUBEADM_CP_ENDPOINT" ] && log_info "Control plane endpoint: $KUBEADM_CP_ENDPOINT"
    if [ "$JOIN_AS_CONTROL_PLANE" = true ]; then
        log_info "HA Mode: joining as control-plane"
    fi
    if [ "$HA_ENABLED" = true ]; then
        log_info "HA Mode: kube-vip enabled"
        log_info "HA VIP: ${HA_VIP_ADDRESS}"
        log_info "HA Interface: ${HA_VIP_INTERFACE}"
    fi
    log_info "=== End of dry-run (no changes made) ==="
}

# Check if --control-planes is present in args (remote vs local mode).
_has_control_planes_flag() {
    for _arg in "$@"; do
        [ "$_arg" = "--control-planes" ] && return 0
    done
    return 1
}

# Runner for subcommands that always operate on remote nodes.
# Usage: _run_remote <subcommand> <parse_fn> <validate_fn> <dry_run_fn> <execute_fn> [args...]
_run_remote() {
    local _cmd="$1" _parse="$2" _validate="$3" _dry_run="$4" _execute="$5"
    shift 5
    "$_parse" "$@"
    "$_validate"
    _dry_run_guard "$_dry_run"
    _require_transferable_script "$_cmd"
    "$_execute"
    exit $?
}

# Runner for subcommands that operate on remote nodes when --control-planes
# is given, and on the local node otherwise.
# Usage: _run_dual_mode <subcommand> <remote_parse> <remote_validate> <remote_dry_run> <remote_execute> \
#                       <root_label> <local_parse> <local_dry_run> <local_execute> [args...]
_run_dual_mode() {
    local _cmd="$1" r_parse="$2" r_validate="$3" r_dry_run="$4" r_execute="$5"
    local root_label="$6" l_parse="$7" l_dry_run="$8" l_execute="$9"
    shift 9
    if _has_control_planes_flag "$@"; then
        _run_remote "$_cmd" "$r_parse" "$r_validate" "$r_dry_run" "$r_execute" "$@"
    fi
    _require_root "$root_label"
    "$l_parse" "$@"
    _dry_run_guard "$l_dry_run"
    "$l_execute"
    exit $?
}

_run_deploy() {
    _run_remote deploy parse_deploy_args validate_deploy_args deploy_dry_run deploy_cluster "$@"
}

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

_run_remove() {
    _run_remote remove parse_remove_args validate_remove_args remove_dry_run remove_cluster "$@"
}

_run_cleanup() {
    _require_root "Cleanup"
    parse_cleanup_args "$@"
    _ensure_distro_detected
    _dry_run_guard cleanup_dry_run
    confirm_cleanup

    CLEANUP_ERRORS=0
    log_info "Starting Kubernetes cleanup..."
    check_docker_warning
    stop_kubernetes_services || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
    stop_cri_services || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
    reset_kubernetes_cluster || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
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
    _dispatch "cleanup_${DISTRO_FAMILY}" || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
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
    log_info "Cleanup complete! Please reboot the system for all changes to take effect."
    exit 0
}

_backup_local_main() { backup_etcd_local; }
_restore_local_main() { restore_etcd_local; }

_run_etcd() {
    if [ "$ACTION" = "backup" ]; then
        _run_dual_mode backup \
            parse_backup_remote_args validate_backup_remote_args backup_dry_run backup_etcd_remote \
            "Local backup" parse_backup_local_args backup_dry_run _backup_local_main \
            "$@"
    else
        _run_dual_mode restore \
            parse_restore_remote_args validate_restore_remote_args restore_dry_run restore_etcd_remote \
            "Local restore" parse_restore_local_args restore_dry_run _restore_local_main \
            "$@"
    fi
}

_run_preflight() {
    _require_root "Preflight checks"
    parse_preflight_args "$@"
    _dry_run_guard preflight_dry_run
    preflight_local
    exit $?
}

_run_renew() {
    _run_dual_mode renew \
        parse_renew_deploy_args validate_renew_deploy_args renew_dry_run renew_cluster \
        "Local certificate renewal" parse_renew_local_args renew_dry_run renew_certs_local \
        "$@"
}

_run_status() {
    parse_status_args "$@"
    _dry_run_guard status_dry_run
    status_local
    exit $?
}

_run_setup() {
    _require_root "This script"

    parse_setup_args "$@"
    validate_join_args
    validate_cri
    validate_completion_options

    if [ -z "${DISTRO_FAMILY:-}" ]; then
        detect_distribution
    fi

    log_info "Installing dependencies..."
    _dispatch "install_dependencies_${DISTRO_FAMILY}"
    determine_k8s_version
    validate_proxy_mode
    validate_swap_enabled
    validate_ha_args

    if [ "$DRY_RUN" = true ]; then
        _setup_dry_run
        exit 0
    fi

    log_info "Starting Kubernetes initialization script..."
    log_info "Action: ${ACTION}"
    log_info "Container Runtime: ${CRI}"
    log_info "Proxy mode: ${PROXY_MODE}"
    log_info "Swap enabled: ${SWAP_ENABLED}"
    log_info "Kubernetes Version (minor): ${K8S_VERSION}"

    if [ "$SWAP_ENABLED" != true ]; then
        disable_swap
        disable_zram_swap
    fi

    enable_kernel_modules
    configure_network_settings

    if [ "$PROXY_MODE" = "ipvs" ]; then
        check_ipvs_availability
    fi
    if [ "$PROXY_MODE" = "nftables" ]; then
        check_nftables_availability
    fi

    log_info "Setting up container runtime: ${CRI}..."
    if [ "$CRI" = "containerd" ]; then
        _dispatch "setup_containerd_${DISTRO_FAMILY}"
    else
        _dispatch "setup_crio_${DISTRO_FAMILY}"
    fi

    log_info "Setting up Kubernetes..."
    _dispatch "setup_kubernetes_${DISTRO_FAMILY}"

    log_info "Performing pre-installation cleanup..."
    cleanup_pre_common
    cleanup_kube_configs
    reset_iptables

    if [ "$ACTION" = "init" ]; then
        initialize_cluster
    else
        join_cluster
    fi

    show_versions
    setup_helm
    setup_kustomize
    setup_k8s_shell_completion
    log_info "Setup completed successfully!"
}
