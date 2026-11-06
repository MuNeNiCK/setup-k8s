#!/usr/bin/env bats
# Ported from test/unit/test_preflight.sh

setup() {
    load '../helpers/common'
}

# File-local module loaders
_load_preflight_test_modules() {
    load_modules
}

_load_preflight_ssh_test_modules() {
    _load_preflight_test_modules
}

# ============================================================
# Test: PREFLIGHT_* variable defaults
# ============================================================
_case_preflight_variables_defaults() {
    echo "=== Test: PREFLIGHT_* variable defaults ==="
    (
        load_modules
        _assert_eq "PREFLIGHT_MODE default" "init" "$PREFLIGHT_MODE"
        _assert_eq "PREFLIGHT_CRI default" "containerd" "$PREFLIGHT_CRI"
        _assert_eq "PREFLIGHT_PROXY_MODE default" "auto" "$PREFLIGHT_PROXY_MODE"
        _assert_eq "PREFLIGHT_K8S_VERSION default" "" "$PREFLIGHT_K8S_VERSION"
    )
}

# ============================================================
# Test: parse_preflight_args
# ============================================================
_case_parse_preflight_args() {
    echo "=== Test: parse_preflight_args ==="
    (
        load_modules

        parse_preflight_args --mode join --cri crio --proxy-mode ipvs --kubernetes-version 1.36
        _assert_eq "PREFLIGHT_MODE parsed" "join" "$PREFLIGHT_MODE"
        _assert_eq "PREFLIGHT_CRI parsed" "crio" "$PREFLIGHT_CRI"
        _assert_eq "PREFLIGHT_PROXY_MODE parsed" "ipvs" "$PREFLIGHT_PROXY_MODE"
        _assert_eq "PREFLIGHT_K8S_VERSION parsed" "1.36" "$PREFLIGHT_K8S_VERSION"
    )
}

# ============================================================
# Test: parse_preflight_args rejects invalid --mode
# ============================================================
_case_parse_preflight_args_invalid_mode() {
    echo "=== Test: parse_preflight_args rejects invalid --mode ==="
    (
        load_modules

        local exit_code=0
        (parse_preflight_args --mode upgrade) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "invalid --mode rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: parse_preflight_args rejects unknown option
# ============================================================
_case_parse_preflight_unknown_option() {
    echo "=== Test: parse_preflight_args unknown option ==="
    (
        load_modules

        local exit_code=0
        (parse_preflight_args --bogus-flag) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "unknown option rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: preflight --help exits 0
# ============================================================
_case_preflight_help_exit() {
    echo "=== Test: preflight --help exits 0 ==="
    _assert_exit_code "setup-k8s.sh preflight --help exits 0" 0 bash "$PROJECT_ROOT/setup-k8s.sh" preflight --help
}

# ============================================================
# Test: help text contains 'preflight'
# ============================================================
_case_help_contains_preflight() {
    echo "=== Test: help text contains preflight ==="
    (
        local help_out
        help_out=$(bash "$PROJECT_ROOT/setup-k8s.sh" --help 2>&1)
        local has_preflight="false"
        if echo "$help_out" | grep -q 'preflight'; then has_preflight="true"; fi
        _assert_eq "help contains preflight" "true" "$has_preflight"
    )
}

# ============================================================
# Test: _preflight_check_cpu runs
# ============================================================
_case_preflight_check_cpu() {
    echo "=== Test: _preflight_check_cpu runs ==="
    (
        load_modules

        local out
        out=$(_preflight_check_cpu 2>&1)
        # Should output something about CPU
        local has_cpu="false"
        if echo "$out" | grep -qi 'cpu'; then has_cpu="true"; fi
        _assert_eq "cpu check produces output" "true" "$has_cpu"
    )
}

# ============================================================
# Test: _preflight_check_memory runs
# ============================================================
_case_preflight_check_memory() {
    echo "=== Test: _preflight_check_memory runs ==="
    (
        _load_preflight_ssh_test_modules

        local out
        out=$(_preflight_check_memory 2>&1)
        # Should output something about memory
        local has_mem="false"
        if echo "$out" | grep -qi 'memory\|memtotal\|MB'; then has_mem="true"; fi
        _assert_eq "memory check produces output" "true" "$has_mem"
    )
}

# ============================================================
# Test: preflight strict default
# ============================================================
_case_preflight_strict_default() {
    echo "=== Test: preflight strict default ==="
    (
        load_modules
        _assert_eq "PREFLIGHT_STRICT default" "false" "$PREFLIGHT_STRICT"
    )
}

# ============================================================
# Test: parse preflight --preflight-strict
# ============================================================
_case_parse_preflight_strict() {
    echo "=== Test: parse preflight --preflight-strict ==="
    (
        load_modules
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        _require_value() { [ "$1" -ge 2 ] || { echo "missing value for $2" >&2; exit 1; }; }

        parse_preflight_args --preflight-strict
        _assert_eq "PREFLIGHT_STRICT parsed" "true" "$PREFLIGHT_STRICT"
    )
}

# ============================================================
# Test: preflight new check functions defined
# ============================================================
_case_preflight_new_checks_defined() {
    echo "=== Test: preflight new check functions defined ==="
    (
        load_modules
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        _require_value() { :; }
        _preflight_record_pass() { :; }; _preflight_record_fail() { :; }; _preflight_record_warn() { :; }

        local has_selinux="false"
        type _preflight_check_selinux >/dev/null 2>&1 && has_selinux="true"
        _assert_eq "_preflight_check_selinux defined" "true" "$has_selinux"

        local has_apparmor="false"
        type _preflight_check_apparmor >/dev/null 2>&1 && has_apparmor="true"
        _assert_eq "_preflight_check_apparmor defined" "true" "$has_apparmor"

        local has_unattended="false"
        type _preflight_check_unattended_upgrades >/dev/null 2>&1 && has_unattended="true"
        _assert_eq "_preflight_check_unattended_upgrades defined" "true" "$has_unattended"
    )
}

@test "PREFLIGHT_* variable defaults" {
    _case_preflight_variables_defaults
}

@test "parse_preflight_args" {
    _case_parse_preflight_args
}

@test "parse_preflight_args rejects invalid --mode" {
    _case_parse_preflight_args_invalid_mode
}

@test "parse_preflight_args unknown option" {
    _case_parse_preflight_unknown_option
}

@test "preflight --help exits 0" {
    _case_preflight_help_exit
}

@test "help text contains preflight" {
    _case_help_contains_preflight
}

@test "_preflight_check_cpu runs" {
    _case_preflight_check_cpu
}

@test "_preflight_check_memory runs" {
    _case_preflight_check_memory
}

@test "preflight strict default" {
    _case_preflight_strict_default
}

@test "parse preflight --preflight-strict" {
    _case_parse_preflight_strict
}

@test "preflight new check functions defined" {
    _case_preflight_new_checks_defined
}

@test "SELinux Enforcing is reported as info, not as a warning" {
    load_modules
    fake_cmd getenforce 0 Enforcing
    _PREFLIGHT_WARN=0
    run _preflight_check_selinux
    [ "$status" -eq 0 ]
    [[ "$output" == *"[INFO] SELinux mode: Enforcing"* ]]
    _preflight_check_selinux 2>/dev/null
    [ "$_PREFLIGHT_WARN" -eq 0 ]
}

@test "containerd 1.x fails preflight for Kubernetes 1.38+ and warns before" {
    load_modules
    fake_cmd containerd 0 "containerd github.com/containerd/containerd v1.7.28 abc"
    _PREFLIGHT_FAIL=0 _PREFLIGHT_WARN=0
    PREFLIGHT_K8S_VERSION=1.38
    _preflight_check_containerd_v2_readiness 2>/dev/null
    [ "$_PREFLIGHT_FAIL" -eq 1 ]
    _PREFLIGHT_FAIL=0 _PREFLIGHT_WARN=0
    PREFLIGHT_K8S_VERSION=1.37
    _preflight_check_containerd_v2_readiness 2>/dev/null
    [ "$_PREFLIGHT_FAIL" -eq 0 ]
    [ "$_PREFLIGHT_WARN" -eq 1 ]
}

@test "preflight reports user namespace support and SELinuxMount as info" {
    load_modules
    _kernel_release() { echo "6.8.0"; }
    run _preflight_check_user_namespaces
    [[ "$output" == *"User namespaces for Pods: available"* ]]
    _kernel_release() { echo "5.14.0"; }
    run _preflight_check_user_namespaces
    [[ "$output" == *"not available (kernel 5.14.0"* ]]
    fake_cmd getenforce 0 Enforcing
    PREFLIGHT_K8S_VERSION=1.37
    run _preflight_check_selinux
    [[ "$output" == *"SELinuxMount"* ]]
    PREFLIGHT_K8S_VERSION=1.36
    run _preflight_check_selinux
    [[ "$output" != *"SELinuxMount"* ]]
}
