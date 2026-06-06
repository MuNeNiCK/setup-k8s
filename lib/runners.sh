#!/bin/sh

# Subcommand runner functions for setup-k8s.sh.
# Each _run_* function handles module loading, argument parsing, and execution
# for its respective subcommand.
#
# Requires: bootstrap.sh (module loaders, dispatch, exit traps)
# Requires: setup-k8s.sh globals (_STDIN_MODE, SCRIPT_DIR, ACTION, _RESTORE_CLI_ARGS, etc.)

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

# Helper: load modules for remote-mode subcommands (deploy/upgrade/remove/etcd/renew).
# In local checkout mode, sources from SCRIPT_DIR/lib/; in curl|sh mode, downloads all.
# Usage: _load_remote_modules "mod1 mod2 ..."
_load_remote_modules() {
    local _modules="$1"
    if [ "$_STDIN_MODE" = false ] && [ -d "$SCRIPT_DIR/lib" ]; then
        _load_module_set "$_modules"
    else
        load_deploy_modules
        for _mod in $_modules; do
            if [ -f "$DEPLOY_MODULES_DIR/lib/${_mod}.sh" ]; then
                . "$DEPLOY_MODULES_DIR/lib/${_mod}.sh"
            elif [ -f "$DEPLOY_MODULES_DIR/commands/${_mod}.sh" ]; then
                . "$DEPLOY_MODULES_DIR/commands/${_mod}.sh"
            fi
        done
        SCRIPT_DIR="$DEPLOY_MODULES_DIR"
    fi
}

# Helper: show help for backup/restore based on ACTION
_show_etcd_help_by_action() {
    if [ "$ACTION" = "backup" ]; then show_backup_help; else show_restore_help; fi
}

# Shared runner for simple remote-mode subcommands (load -> parse -> validate -> dry-run -> execute).
# Usage: _run_simple_remote <modules> <parse_fn> <validate_fn> <dry_run_fn> <execute_fn>
_run_simple_remote() {
    local _modules="$1" _parse="$2" _validate="$3" _dry_run="$4" _execute="$5"
    _load_remote_modules "$_modules"
    eval "$_RESTORE_CLI_ARGS"
    "$_parse" "$@"
    "$_validate"
    _dry_run_guard "$_dry_run"
    "$_execute"
    exit $?
}

# Runner for dual-mode subcommands (remote via --control-planes, or local).
# Remote branch: load -> parse -> validate -> dry-run -> execute
# Local branch: help -> root -> load -> parse -> [dry-run ->] execute
# Usage: _run_dual_mode <remote_modules> <remote_parse> <remote_validate> <remote_dry_run> <remote_execute> \
#                        <help_fn> <root_label> <local_loader> <local_parse> <local_dry_run> <local_execute>
_run_dual_mode() {
    local r_modules="$1" r_parse="$2" r_validate="$3" r_dry_run="$4" r_execute="$5"
    local help_fn="$6" root_label="$7" l_loader="$8" l_parse="$9"
    shift 9
    local l_dry_run="$1" l_execute="$2"
    eval "$_RESTORE_CLI_ARGS"
    if _has_control_planes_flag "$@"; then
        _load_remote_modules "$r_modules"
        eval "$_RESTORE_CLI_ARGS"
        "$r_parse" "$@"
        "$r_validate"
        _dry_run_guard "$r_dry_run"
        "$r_execute"
        exit $?
    else
        eval "$_RESTORE_CLI_ARGS"
        _show_help_if_requested "$help_fn" "$@"
        _require_root "$root_label"
        "$l_loader"
        eval "$_RESTORE_CLI_ARGS"
        "$l_parse" "$@"
        _dry_run_guard "$l_dry_run"
        "$l_execute"
        exit $?
    fi
}

_run_deploy() {
    _run_simple_remote \
        "variables logging validation helpers ssh_args ssh ssh_credentials ssh_session bundle health diagnostics state deploy" \
        parse_deploy_args validate_deploy_args deploy_dry_run deploy_cluster
}

_run_upgrade() {
    _load_upgrade_local() {
        if { [ "$_STDIN_MODE" = false ] && [ -d "$SCRIPT_DIR/lib" ]; } || [ "$BUNDLED_MODE" = "true" ]; then
            run_local "parse_upgrade_local_args" "$_UPGRADE_LOCAL_CMD_MODULES $_UPGRADE_LOCAL_LIB_MODULES" dependencies containerd crio kubernetes
        else
            load_modules "setup-k8s" "$_UPGRADE_LOCAL_CMD_MODULES" "$_UPGRADE_LOCAL_LIB_MODULES" dependencies containerd crio kubernetes
        fi
        _ensure_distro_detected
    }
    _run_dual_mode \
        "variables logging validation helpers ssh_args ssh ssh_credentials ssh_session bundle health diagnostics state deploy upgrade upgrade_orchestration" \
        parse_upgrade_deploy_args validate_upgrade_deploy_args upgrade_dry_run upgrade_cluster \
        show_upgrade_help "Local upgrade" _load_upgrade_local \
        parse_upgrade_local_args upgrade_dry_run upgrade_node_local
}

_run_remove() {
    _run_simple_remote \
        "variables logging validation helpers ssh_args ssh ssh_credentials ssh_session bundle health diagnostics state deploy remove" \
        parse_remove_args validate_remove_args remove_dry_run remove_cluster
}

_run_cleanup() {
    eval "$_RESTORE_CLI_ARGS"
    _show_help_if_requested show_cleanup_help "$@"
    _require_root "Cleanup"
    if { [ "$_STDIN_MODE" = false ] && [ -d "$SCRIPT_DIR/lib" ]; } || [ "$BUNDLED_MODE" = "true" ]; then
        run_local "parse_cleanup_args" "$_CLEANUP_CMD_MODULES $_CLEANUP_LIB_MODULES" dependencies cleanup
    else
        load_modules "setup-k8s" "$_CLEANUP_CMD_MODULES" "$_CLEANUP_LIB_MODULES" dependencies cleanup
    fi
    eval "$_RESTORE_CLI_ARGS"
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

_run_etcd() {
    eval "$_RESTORE_CLI_ARGS"
    if _has_control_planes_flag "$@"; then
        _load_remote_modules "variables logging validation helpers ssh_args ssh ssh_credentials ssh_session bundle deploy etcd_helpers etcd_common backup restore"
        eval "$_RESTORE_CLI_ARGS"
        if [ "$ACTION" = "backup" ]; then
            parse_backup_remote_args "$@"
            validate_backup_remote_args
            _dry_run_guard backup_dry_run
            backup_etcd_remote
        else
            parse_restore_remote_args "$@"
            validate_restore_remote_args
            _dry_run_guard restore_dry_run
            restore_etcd_remote
        fi
        exit $?
    else
        eval "$_RESTORE_CLI_ARGS"
        _show_help_if_requested _show_etcd_help_by_action "$@"
        _require_root "Local backup/restore"
        if { [ "$_STDIN_MODE" = false ] && [ -d "$SCRIPT_DIR/lib" ]; } || [ "$BUNDLED_MODE" = "true" ]; then
            run_local "parse_backup_local_args" "$_ETCD_LOCAL_CMD_MODULES $_ETCD_LOCAL_LIB_MODULES" dependencies containerd crio kubernetes
        else
            load_modules "setup-k8s" "$_ETCD_LOCAL_CMD_MODULES" "$_ETCD_LOCAL_LIB_MODULES" dependencies containerd crio kubernetes
        fi
        eval "$_RESTORE_CLI_ARGS"
        if [ "$ACTION" = "backup" ]; then
            parse_backup_local_args "$@"
            _dry_run_guard backup_dry_run
            backup_etcd_local
        else
            parse_restore_local_args "$@"
            _dry_run_guard restore_dry_run
            restore_etcd_local
        fi
        exit $?
    fi
}

_run_preflight() {
    local preflight_modules="variables logging detection validation system helpers preflight"
    _load_local_modules preflight "$preflight_modules"
    eval "$_RESTORE_CLI_ARGS"
    _show_help_if_requested show_preflight_help "$@"
    _require_root "Preflight checks"
    eval "$_RESTORE_CLI_ARGS"
    parse_preflight_args "$@"
    _dry_run_guard preflight_dry_run
    preflight_local
    exit $?
}

_run_renew() {
    _load_renew_local() {
        local renew_local_modules="variables logging detection validation system helpers renew"
        _load_local_modules renew "$renew_local_modules"
    }
    _run_dual_mode \
        "variables logging validation helpers ssh_args ssh ssh_credentials ssh_session bundle deploy renew" \
        parse_renew_deploy_args validate_renew_deploy_args renew_dry_run renew_cluster \
        show_renew_help "Local certificate renewal" _load_renew_local \
        parse_renew_local_args renew_dry_run renew_certs_local
}

_run_status() {
    local status_modules="variables logging validation system helpers etcd_helpers status"
    _load_local_modules status "$status_modules"
    eval "$_RESTORE_CLI_ARGS"
    parse_status_args "$@"
    _dry_run_guard status_dry_run
    status_local
    exit $?
}

_run_setup() {
    _require_root "This script"

    if { [ "$_STDIN_MODE" = false ] && [ -d "$SCRIPT_DIR/lib" ]; } || [ "$BUNDLED_MODE" = "true" ]; then
        run_local "parse_setup_args" "$_SETUP_CMD_MODULES $_SETUP_LIB_MODULES" dependencies containerd crio kubernetes
    else
        load_modules "setup-k8s" "$_SETUP_CMD_MODULES" "$_SETUP_LIB_MODULES" dependencies containerd crio kubernetes
    fi

    eval "$_RESTORE_CLI_ARGS"
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

_error_missing_subcommand() {
    echo "Error: Missing subcommand. Valid subcommands: init, join, deploy, upgrade, remove, backup, restore, cleanup, status, preflight, renew" >&2
    echo "Run with --help for usage information" >&2
    exit 1
}
