#!/bin/sh
# Unit tests for commands/preflight.sh

# File-local module loaders
_load_preflight_test_modules() {
    source "$PROJECT_ROOT/lib/variables.sh"
    source "$PROJECT_ROOT/lib/logging.sh"
    source "$PROJECT_ROOT/lib/validation.sh"
    source "$PROJECT_ROOT/lib/helpers.sh"
}

_load_preflight_ssh_test_modules() {
    _load_preflight_test_modules
    source "$PROJECT_ROOT/lib/ssh_args.sh"
    source "$PROJECT_ROOT/lib/ssh.sh"
    source "$PROJECT_ROOT/lib/ssh_session.sh"
}

# ============================================================
# Test: PREFLIGHT_* variable defaults
# ============================================================
test_preflight_variables_defaults() {
    echo "=== Test: PREFLIGHT_* variable defaults ==="
    (
        source "$PROJECT_ROOT/lib/variables.sh"
        _assert_eq "PREFLIGHT_MODE default" "init" "$PREFLIGHT_MODE"
        _assert_eq "PREFLIGHT_CRI default" "containerd" "$PREFLIGHT_CRI"
        _assert_eq "PREFLIGHT_PROXY_MODE default" "iptables" "$PREFLIGHT_PROXY_MODE"
        _assert_eq "PREFLIGHT_K8S_VERSION default" "" "$PREFLIGHT_K8S_VERSION"
    )
}

# ============================================================
# Test: parse_preflight_args
# ============================================================
test_parse_preflight_args() {
    echo "=== Test: parse_preflight_args ==="
    (
        source "$PROJECT_ROOT/lib/variables.sh"
        source "$PROJECT_ROOT/lib/logging.sh"
        source "$PROJECT_ROOT/lib/validation.sh"
        source "$PROJECT_ROOT/commands/preflight.sh"

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
test_parse_preflight_args_invalid_mode() {
    echo "=== Test: parse_preflight_args rejects invalid --mode ==="
    (
        source "$PROJECT_ROOT/lib/variables.sh"
        source "$PROJECT_ROOT/lib/logging.sh"
        source "$PROJECT_ROOT/lib/validation.sh"
        source "$PROJECT_ROOT/commands/preflight.sh"

        local exit_code=0
        (parse_preflight_args --mode upgrade) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "invalid --mode rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: parse_preflight_args rejects unknown option
# ============================================================
test_parse_preflight_unknown_option() {
    echo "=== Test: parse_preflight_args unknown option ==="
    (
        source "$PROJECT_ROOT/lib/variables.sh"
        source "$PROJECT_ROOT/lib/logging.sh"
        source "$PROJECT_ROOT/lib/validation.sh"
        source "$PROJECT_ROOT/commands/preflight.sh"

        local exit_code=0
        (parse_preflight_args --bogus-flag) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "unknown option rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: preflight --help exits 0
# ============================================================
test_preflight_help_exit() {
    echo "=== Test: preflight --help exits 0 ==="
    _assert_exit_code "setup-k8s.sh preflight --help exits 0" 0 bash "$PROJECT_ROOT/setup-k8s.sh" preflight --help
}

# ============================================================
# Test: help text contains 'preflight'
# ============================================================
test_help_contains_preflight() {
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
test_preflight_check_cpu() {
    echo "=== Test: _preflight_check_cpu runs ==="
    (
        source "$PROJECT_ROOT/lib/variables.sh"
        source "$PROJECT_ROOT/lib/logging.sh"
        source "$PROJECT_ROOT/lib/validation.sh"
        source "$PROJECT_ROOT/commands/preflight.sh"

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
test_preflight_check_memory() {
    echo "=== Test: _preflight_check_memory runs ==="
    (
        _load_preflight_ssh_test_modules
        source "$PROJECT_ROOT/commands/remove.sh"
        source "$PROJECT_ROOT/commands/preflight.sh"

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
test_preflight_strict_default() {
    echo "=== Test: preflight strict default ==="
    (
        . "$PROJECT_ROOT/lib/variables.sh"
        _assert_eq "PREFLIGHT_STRICT default" "false" "$PREFLIGHT_STRICT"
    )
}

# ============================================================
# Test: parse preflight --preflight-strict
# ============================================================
test_parse_preflight_strict() {
    echo "=== Test: parse preflight --preflight-strict ==="
    (
        . "$PROJECT_ROOT/lib/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        _require_value() { [ "$1" -ge 2 ] || { echo "missing value for $2" >&2; exit 1; }; }
        . "$PROJECT_ROOT/commands/preflight.sh"

        parse_preflight_args --preflight-strict
        _assert_eq "PREFLIGHT_STRICT parsed" "true" "$PREFLIGHT_STRICT"
    )
}

# ============================================================
# Test: preflight new check functions defined
# ============================================================
test_preflight_new_checks_defined() {
    echo "=== Test: preflight new check functions defined ==="
    (
        . "$PROJECT_ROOT/lib/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        _require_value() { :; }
        _preflight_record_pass() { :; }; _preflight_record_fail() { :; }; _preflight_record_warn() { :; }
        . "$PROJECT_ROOT/commands/preflight.sh"

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
