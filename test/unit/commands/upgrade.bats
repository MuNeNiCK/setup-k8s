#!/usr/bin/env bats
# Ported from test/unit/test_upgrade.sh

setup() {
    load '../helpers/common'
}

# ============================================================
# Test: UPGRADE_* variable defaults
# ============================================================
_case_upgrade_variables_defaults() {
    echo "=== Test: UPGRADE_* variable defaults ==="
    (
        load_modules
        _assert_eq "UPGRADE_TARGET_VERSION default" "" "$UPGRADE_TARGET_VERSION"
        _assert_eq "UPGRADE_FIRST_CONTROL_PLANE default" "false" "$UPGRADE_FIRST_CONTROL_PLANE"
        _assert_eq "UPGRADE_SKIP_DRAIN default" "false" "$UPGRADE_SKIP_DRAIN"
    )
}

# ============================================================
# Test: parse_upgrade_local_args
# ============================================================
_case_parse_upgrade_local_args() {
    echo "=== Test: parse_upgrade_local_args ==="
    (
        load_modules

        parse_upgrade_local_args --kubernetes-version 1.33.2 --first-control-plane --skip-drain
        _assert_eq "UPGRADE_TARGET_VERSION parsed" "1.33.2" "$UPGRADE_TARGET_VERSION"
        _assert_eq "UPGRADE_FIRST_CONTROL_PLANE parsed" "true" "$UPGRADE_FIRST_CONTROL_PLANE"
        _assert_eq "UPGRADE_SKIP_DRAIN parsed" "true" "$UPGRADE_SKIP_DRAIN"
    )
}

# ============================================================
# Test: upgrade --kubernetes-version format validation
# ============================================================
_case_upgrade_version_format() {
    echo "=== Test: upgrade --kubernetes-version format validation ==="
    (
        load_modules

        # MAJOR.MINOR should be rejected (must be MAJOR.MINOR.PATCH)
        local exit_code=0
        (parse_upgrade_local_args --kubernetes-version 1.33) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "MAJOR.MINOR rejected" "0" "$exit_code"

        # MAJOR.MINOR.PATCH should be accepted
        exit_code=0
        (parse_upgrade_local_args --kubernetes-version 1.33.2) >/dev/null 2>&1 || exit_code=$?
        _assert_eq "MAJOR.MINOR.PATCH accepted" "0" "$exit_code"

        # Missing --kubernetes-version should be rejected
        exit_code=0
        (parse_upgrade_local_args --first-control-plane) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "missing --kubernetes-version rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: _k8s_minor_version extraction
# ============================================================
_case_k8s_minor_version() {
    echo "=== Test: _k8s_minor_version extraction ==="
    (
        load_modules

        _assert_eq "_k8s_minor_version 1.33.2" "1.33" "$(_k8s_minor_version "1.33.2")"
        _assert_eq "_k8s_minor_version 1.28.0" "1.28" "$(_k8s_minor_version "1.28.0")"
        _assert_eq "_k8s_minor_version 2.0.1" "2.0" "$(_k8s_minor_version "2.0.1")"
    )
}

# ============================================================
# Test: _validate_upgrade_version constraints
# ============================================================
_case_validate_upgrade_version() {
    echo "=== Test: _validate_upgrade_version constraints ==="
    (
        load_modules

        # +1 minor should be OK
        local exit_code=0
        (_validate_upgrade_version "1.32.0" "1.33.2") >/dev/null 2>&1 || exit_code=$?
        _assert_eq "+1 minor allowed" "0" "$exit_code"

        # Same minor, higher patch should be OK
        exit_code=0
        (_validate_upgrade_version "1.32.0" "1.32.5") >/dev/null 2>&1 || exit_code=$?
        _assert_eq "patch upgrade allowed" "0" "$exit_code"

        # +2 minor should be rejected
        exit_code=0
        (_validate_upgrade_version "1.31.0" "1.33.0") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "+2 minor rejected" "0" "$exit_code"

        # Downgrade should be rejected
        exit_code=0
        (_validate_upgrade_version "1.33.0" "1.32.0") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "downgrade rejected" "0" "$exit_code"

        # Same version should be rejected
        exit_code=0
        (_validate_upgrade_version "1.33.2" "1.33.2") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "same version rejected" "0" "$exit_code"

        # Patch downgrade should be rejected
        exit_code=0
        (_validate_upgrade_version "1.33.5" "1.33.2") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "patch downgrade rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: _detect_node_role
# ============================================================
_case_detect_node_role() {
    echo "=== Test: _detect_node_role ==="
    (
        load_modules

        # Without kube-apiserver manifest -> worker
        local role
        role=$(_detect_node_role)
        _assert_eq "no manifest = worker" "worker" "$role"

        # With UPGRADE_FIRST_CONTROL_PLANE=false and no manifest -> worker
        UPGRADE_FIRST_CONTROL_PLANE=true
        role=$(_detect_node_role)
        _assert_eq "no manifest + first-cp flag = still worker" "worker" "$role"
    )
}

# ============================================================
# Test: upgrade --help exits 0
# ============================================================
_case_upgrade_help_exit() {
    echo "=== Test: upgrade --help exits 0 ==="
    _assert_exit_code "setup-k8s.sh upgrade --help exits 0" 0 bash "$PROJECT_ROOT/setup-k8s.sh" upgrade --help
}

# ============================================================
# Test: _validate_upgrade_version format validation
# ============================================================
_case_validate_upgrade_version_format() {
    echo "=== Test: _validate_upgrade_version format validation ==="
    (
        load_modules

        # Invalid format should be rejected
        local exit_code=0
        (_validate_upgrade_version "1.32" "1.33.0") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "MAJOR.MINOR current rejected" "0" "$exit_code"

        exit_code=0
        (_validate_upgrade_version "1.32.0" "latest") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "non-numeric target rejected" "0" "$exit_code"

        exit_code=0
        (_validate_upgrade_version "" "1.33.0") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "empty current rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: UPGRADE_NO_ROLLBACK default and --no-rollback parsing
# ============================================================
_case_upgrade_rollback_flag() {
    echo "=== Test: --no-rollback flag ==="
    (
        load_modules

        # Default value
        _assert_eq "UPGRADE_NO_ROLLBACK default" "false" "$UPGRADE_NO_ROLLBACK"

        # Parse --no-rollback in local mode
        UPGRADE_NO_ROLLBACK=false
        parse_upgrade_local_args --kubernetes-version 1.33.2 --no-rollback
        _assert_eq "--no-rollback parsed (local)" "true" "$UPGRADE_NO_ROLLBACK"

        # Parse --no-rollback in deploy mode
        UPGRADE_NO_ROLLBACK=false
        parse_upgrade_deploy_args --control-planes 10.0.0.1 --kubernetes-version 1.33.2 --no-rollback
        _assert_eq "--no-rollback parsed (deploy)" "true" "$UPGRADE_NO_ROLLBACK"
    )
}

# ============================================================
# Test: rollback helper functions exist
# ============================================================
_case_rollback_functions() {
    echo "=== Test: rollback helper functions ==="
    (
        load_modules

        local has_record="false"
        type _record_pre_upgrade_versions >/dev/null 2>&1 && has_record="true"
        _assert_eq "_record_pre_upgrade_versions defined" "true" "$has_record"

        local has_rollback="false"
        type _rollback_node >/dev/null 2>&1 && has_rollback="true"
        _assert_eq "_rollback_node defined" "true" "$has_rollback"
    )
}

# ============================================================
# Test: auto-step-upgrade default
# ============================================================
_case_auto_step_upgrade_default() {
    echo "=== Test: auto-step-upgrade default ==="
    (
        load_modules
        _assert_eq "UPGRADE_AUTO_STEP default" "false" "$UPGRADE_AUTO_STEP"
    )
}

# ============================================================
# Test: parse --auto-step-upgrade
# ============================================================
_case_parse_auto_step_upgrade() {
    echo "=== Test: parse --auto-step-upgrade ==="
    (
        load_modules
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        _require_value() { [ "$1" -ge 2 ] || { echo "missing value for $2" >&2; exit 1; }; }
        _parse_distro_arg() { :; }

        parse_upgrade_local_args --kubernetes-version 1.33.2 --auto-step-upgrade
        _assert_eq "UPGRADE_AUTO_STEP parsed (local)" "true" "$UPGRADE_AUTO_STEP"
    )
}

# ============================================================
# Test: _compute_upgrade_steps function defined
# ============================================================
_case_compute_upgrade_steps_defined() {
    echo "=== Test: _compute_upgrade_steps function defined ==="
    (
        load_modules
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        _require_value() { :; }

        local has_func="false"
        type _compute_upgrade_steps >/dev/null 2>&1 && has_func="true"
        _assert_eq "_compute_upgrade_steps defined" "true" "$has_func"
    )
}

@test "UPGRADE_* variable defaults" {
    _case_upgrade_variables_defaults
}

@test "parse_upgrade_local_args" {
    _case_parse_upgrade_local_args
}

@test "upgrade --kubernetes-version format validation" {
    _case_upgrade_version_format
}

@test "_k8s_minor_version extraction" {
    _case_k8s_minor_version
}

@test "_validate_upgrade_version constraints" {
    _case_validate_upgrade_version
}

@test "_detect_node_role" {
    _case_detect_node_role
}

@test "upgrade --help exits 0" {
    _case_upgrade_help_exit
}

@test "_validate_upgrade_version format validation" {
    _case_validate_upgrade_version_format
}

@test "--no-rollback flag" {
    _case_upgrade_rollback_flag
}

@test "rollback helper functions" {
    _case_rollback_functions
}

@test "auto-step-upgrade default" {
    _case_auto_step_upgrade_default
}

@test "parse --auto-step-upgrade" {
    _case_parse_auto_step_upgrade
}

@test "_compute_upgrade_steps function defined" {
    _case_compute_upgrade_steps_defined
}
