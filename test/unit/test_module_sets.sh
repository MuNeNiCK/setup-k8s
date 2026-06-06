#!/bin/sh
# Unit tests: verify per-subcommand module sets contain all required functions.
#
# For each module set, source ONLY the declared modules and check that every
# function called by the runner (and its command modules) is defined.

# Helper: source a module set and check that listed functions are defined.
# Usage: _check_module_set <description> <lib_modules> <cmd_modules> <fn1> [fn2 ...]
_check_module_set() {
    local desc="$1" lib_modules="$2" cmd_modules="$3"; shift 3

    local missing=""
    # Run in subshell to isolate sourced modules
    missing=$(
        # Source bootstrap (always available at runtime)
        . "$PROJECT_ROOT/lib/bootstrap.sh" >/dev/null 2>&1 || true
        # Source lib modules
        for mod in $lib_modules; do
            [ -f "$PROJECT_ROOT/lib/${mod}.sh" ] && . "$PROJECT_ROOT/lib/${mod}.sh"
        done
        # Source command modules
        for mod in $cmd_modules; do
            [ -f "$PROJECT_ROOT/commands/${mod}.sh" ] && . "$PROJECT_ROOT/commands/${mod}.sh"
        done
        # Check each function
        for fn in "$@"; do
            if ! type "$fn" >/dev/null 2>&1; then
                printf '%s ' "$fn"
            fi
        done
    )

    if [ -z "$missing" ]; then
        _assert_eq "$desc" "" ""
    else
        _assert_eq "$desc: missing functions" "" "$missing"
    fi
}

# ============================================================
# Test: _SETUP module set covers _run_setup functions
# ============================================================
test_module_set_setup() {
    echo "=== Test: module set completeness - setup ==="
    (
        . "$PROJECT_ROOT/lib/bootstrap.sh" >/dev/null 2>&1 || true

        _check_module_set "setup module set" \
            "$_SETUP_LIB_MODULES" "$_SETUP_CMD_MODULES" \
            parse_setup_args validate_join_args validate_cri validate_completion_options \
            detect_distribution determine_k8s_version \
            validate_proxy_mode validate_swap_enabled validate_ha_args \
            disable_swap disable_zram_swap \
            enable_kernel_modules configure_network_settings \
            check_ipvs_availability check_nftables_availability \
            cleanup_pre_common cleanup_kube_configs reset_iptables \
            initialize_cluster join_cluster \
            show_versions setup_helm setup_kustomize setup_k8s_shell_completion \
            log_info log_error
    )
}

# ============================================================
# Test: _CLEANUP module set covers _run_cleanup functions
# ============================================================
test_module_set_cleanup() {
    echo "=== Test: module set completeness - cleanup ==="
    (
        . "$PROJECT_ROOT/lib/bootstrap.sh" >/dev/null 2>&1 || true

        _check_module_set "cleanup module set" \
            "$_CLEANUP_LIB_MODULES" "$_CLEANUP_CMD_MODULES" \
            parse_cleanup_args cleanup_dry_run confirm_cleanup \
            check_docker_warning stop_kubernetes_services stop_cri_services \
            reset_kubernetes_cluster remove_kubernetes_configs \
            restore_fstab_swap restore_zram_swap \
            cleanup_cni_conditionally cleanup_network_configs \
            cleanup_kube_configs cleanup_crictl_config \
            reset_iptables reset_containerd_config \
            _service_reload \
            cleanup_kubernetes_completions cleanup_helm cleanup_kustomize \
            detect_distribution log_info log_error
    )
}

# ============================================================
# Test: _UPGRADE_LOCAL module set covers _run_upgrade local functions
# ============================================================
test_module_set_upgrade_local() {
    echo "=== Test: module set completeness - upgrade local ==="
    (
        . "$PROJECT_ROOT/lib/bootstrap.sh" >/dev/null 2>&1 || true

        _check_module_set "upgrade local module set" \
            "$_UPGRADE_LOCAL_LIB_MODULES" "$_UPGRADE_LOCAL_CMD_MODULES" \
            parse_upgrade_local_args upgrade_dry_run upgrade_node_local \
            _detect_node_role _get_current_k8s_version _validate_upgrade_version \
            _k8s_minor_version _kubeadm_preflight_ignore_args \
            _detect_init_system _service_reload _service_restart \
            show_versions detect_distribution \
            _log_node_list _log_ssh_settings \
            log_info log_warn log_error
    )
}

# ============================================================
# Test: _ETCD_LOCAL module set covers _run_etcd local functions
# ============================================================
test_module_set_etcd_local() {
    echo "=== Test: module set completeness - etcd local ==="
    (
        . "$PROJECT_ROOT/lib/bootstrap.sh" >/dev/null 2>&1 || true

        _check_module_set "etcd local module set" \
            "$_ETCD_LOCAL_LIB_MODULES" "$_ETCD_LOCAL_CMD_MODULES" \
            parse_backup_local_args parse_restore_local_args \
            backup_dry_run backup_etcd_local \
            restore_dry_run restore_etcd_local \
            _find_etcd_container _etcdctl_exec _extract_etcd_binaries \
            _audit_log detect_distribution \
            log_info log_warn log_error
    )
}
