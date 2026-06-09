#!/bin/bash
#
# Simple unit test framework for setup-k8s
# Run: bash test/unit/run.sh
#

set -euo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(cd "$UNIT_DIR/.." && pwd)"
# shellcheck disable=SC2034 # used by test/unit/*.sh via source
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"

# Temporary file for collecting assertion results across subshells
_RESULTS_FILE=$(mktemp -t unit-test-results-XXXXXX)
# shellcheck disable=SC2329 # invoked indirectly via trap
_cleanup_results() { rm -f "$_RESULTS_FILE"; }
trap _cleanup_results EXIT

# Test helpers — append PASS/FAIL to temp file so subshell results are visible
_assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $desc"
        echo "PASS" >> "$_RESULTS_FILE"
    else
        echo "  FAIL: $desc (expected='$expected', actual='$actual')"
        echo "FAIL" >> "$_RESULTS_FILE"
    fi
}

_assert_ne() {
    local desc="$1" not_expected="$2" actual="$3"
    if [ "$not_expected" != "$actual" ]; then
        echo "  PASS: $desc"
        echo "PASS" >> "$_RESULTS_FILE"
    else
        echo "  FAIL: $desc (should not be '$not_expected')"
        echo "FAIL" >> "$_RESULTS_FILE"
    fi
}

_assert_exit_code() {
    local desc="$1" expected_code="$2"
    shift 2
    local actual_code=0
    "$@" >/dev/null 2>&1 || actual_code=$?
    if [ "$expected_code" -eq "$actual_code" ]; then
        echo "  PASS: $desc"
        echo "PASS" >> "$_RESULTS_FILE"
    else
        echo "  FAIL: $desc (expected exit=$expected_code, actual exit=$actual_code)"
        echo "FAIL" >> "$_RESULTS_FILE"
    fi
}

# ============================================================
# Source all topic-based test files
# ============================================================
for f in "$UNIT_DIR/"*.sh; do
    [ "$(basename "$f")" = "run.sh" ] && continue
    . "$f"
done

# ============================================================
# Run all tests
# ============================================================
echo "Running setup-k8s unit tests..."
echo ""

# --- variables & logging ---
test_variables_defaults
test_logging

# --- networking (kernel version comparison) ---
test_kernel_version_comparison

# --- parsing & validation ---
test_parse_setup_args
test_parse_ha_args
test_parse_ha_kube_vip_args
test_kube_vip_kubeconfig_path
test_generate_kube_vip_manifest
test_validate_ha_join_cp
test_require_value
test_unknown_option_exit_code
test_help_early_exit
test_validate_proxy_mode
test_pipefail_safety
test_setup_dry_run_output

# --- swap ---
test_swap_enabled_default
test_parse_swap_enabled
test_validate_swap_enabled
test_help_contains_swap
test_deploy_parse_swap_enabled

# --- upgrade ---
test_upgrade_variables_defaults
test_parse_upgrade_local_args
test_upgrade_version_format
test_k8s_minor_version
test_validate_upgrade_version
test_detect_node_role
test_help_contains_upgrade
test_upgrade_help_exit

# --- IPv6 ---
test_is_ipv6
test_validate_ipv6_addr
test_validate_cidr_ipv6
test_parse_setup_args_ipv6
test_parse_setup_args_dual_stack
test_validate_ha_args_ipv6
test_join_address_ipv6_example
test_generate_kube_vip_manifest_ipv6

# --- detection ---
test_parse_distro_override
test_parse_distro_invalid
test_detect_arch
test_detect_init_system

# --- misc (download) ---
test_download_binary_failure

# --- etcd ---
test_etcd_variables_defaults
test_parse_backup_local_args
test_parse_backup_local_args_default_path
test_parse_restore_local_args_required
test_parse_backup_remote_args
test_parse_restore_remote_args
test_validate_backup_remote_args
test_backup_restore_unknown_option
test_backup_help_exit
test_restore_help_exit
test_help_contains_backup_restore

# --- parsing & validation (continued) ---
test_validate_join_args
test_validate_cri
test_normalize_node_list
test_validate_node_addresses
test_validate_upgrade_version_format

# --- status ---
test_status_output_format_default
test_parse_status_args
test_parse_status_args_invalid_output
test_parse_status_unknown_option
test_status_help_exit

# --- preflight ---
test_preflight_variables_defaults
test_parse_preflight_args
test_parse_preflight_args_invalid_mode
test_parse_preflight_unknown_option
test_preflight_help_exit
test_help_contains_preflight
test_preflight_check_cpu
test_preflight_check_memory

# --- remove & cleanup ---
test_remove_variables_defaults
test_parse_remove_args
test_parse_remove_unknown_option
test_validate_remove_args_required
test_validate_remove_args_cp_safety
test_remove_help_exit
test_cleanup_help_exit
test_help_contains_remove_cleanup

# --- renew ---
test_renew_variables_defaults
test_parse_renew_local_args
test_parse_renew_deploy_args
test_validate_renew_deploy_args_required
test_renew_help_exit
test_help_contains_renew
test_validate_cert_names
test_parse_renew_unknown_option

# --- SSH / deploy ---
test_build_join_cmd
test_deploy_timeout_defaults
test_parse_node_address
test_build_deploy_ssh_opts
test_session_known_hosts
test_bundle_dir_store
test_validate_ssh_key_permissions
test_load_ssh_password_file
test_timeout_cli_options
test_health_functions

# --- logging (file/audit) ---
test_file_logging
test_audit_logging

# --- diagnostics ---
test_diagnostics_functions

# --- upgrade (rollback) ---
test_upgrade_rollback_flag
test_rollback_functions

# --- networking (options, kubeadm config) ---
test_network_options_defaults
test_parse_network_options
test_generate_kubeadm_config_extra_sans
test_generate_kubeadm_config_patch

# --- preflight (strict, new checks) ---
test_preflight_strict_default
test_parse_preflight_strict
test_preflight_new_checks_defined

# --- upgrade (auto-step) ---
test_auto_step_upgrade_default
test_parse_auto_step_upgrade
test_compute_upgrade_steps_defined

# --- state ---
# --- module set completeness ---
test_module_set_setup
test_module_set_cleanup
test_module_set_upgrade_local
test_module_set_upgrade_remote
test_module_set_etcd_local
test_module_set_deploy_remote

test_state_functions_defined
test_state_set_get
test_state_mark_step_done
test_state_find_resume
test_resume_enabled_default

# --- bootstrap (CSV, passthrough, quote, cleanup, validation) ---
test_csv_count
test_csv_get
test_append_passthrough_to_cmd
test_append_passthrough_filtered
test_posix_shell_quote
test_etcd_functions_defined
test_networking_functions_defined
test_swap_functions_defined
test_detect_distro_family_mapping
test_has_cgroupv2
test_completion_functions_defined
test_cleanup_handlers
test_validate_shell_module
test_csv_any

# --- deep logic tests ---
test_build_ssh_opts_key_only
test_build_ssh_opts_password
test_build_ssh_opts_ssh_agent
test_build_ssh_opts_agent_with_key
test_parse_node_address_bare_host
test_parse_node_address_user_at_host
test_parse_node_address_ipv6_bracketed
test_parse_node_address_bare_ipv6
test_posix_shell_quote_precise
test_passthrough_special_chars
test_passthrough_filtered_ha_interface
test_bundle_dir_store_deep
test_session_known_hosts_lifecycle
test_session_known_hosts_seeded
test_etcd_backup_path_variables
test_kernel_modules_iptables_mode
test_kernel_modules_ipvs_list
test_kernel_modules_nftables_list
test_sysctl_settings_content
test_swap_fstab_sed_pattern
test_detect_distro_family_all_mappings
test_find_etcd_container_error
test_find_etcd_container_inspect_fallback
test_resolve_etcd_image_ref_prefers_name
test_resolve_etcd_image_ref_ctr_fallback
test_ssh_key_permission_validation
test_ssh_password_file_loading
test_persist_known_hosts
test_install_proxy_mode_packages_logic
test_build_scp_args_ipv6
test_csv_edge_cases
test_log_ssh_settings
test_ssh_host_key_check_default
test_auto_discover_ssh_key

echo ""
TESTS_RUN=$(wc -l < "$_RESULTS_FILE")
TESTS_PASSED=$(grep -c '^PASS$' "$_RESULTS_FILE" || true)
TESTS_FAILED=$(grep -c '^FAIL$' "$_RESULTS_FILE" || true)
echo "==================================="
echo "Results: $TESTS_RUN tests, $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "==================================="

if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
