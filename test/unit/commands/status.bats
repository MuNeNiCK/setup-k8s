#!/usr/bin/env bats
# Ported from test/unit/test_status.sh

setup() {
    load '../helpers/common'
}

# ============================================================
# Test: STATUS_OUTPUT_FORMAT default
# ============================================================
_case_status_output_format_default() {
    echo "=== Test: STATUS_OUTPUT_FORMAT default ==="
    (
        load_modules
        _assert_eq "STATUS_OUTPUT_FORMAT default" "text" "$STATUS_OUTPUT_FORMAT"
    )
}

# ============================================================
# Test: parse_status_args
# ============================================================
_case_parse_status_args() {
    echo "=== Test: parse_status_args ==="
    (
        load_modules

        parse_status_args --output wide
        _assert_eq "STATUS_OUTPUT_FORMAT parsed" "wide" "$STATUS_OUTPUT_FORMAT"
    )
}

# ============================================================
# Test: parse_status_args rejects invalid --output
# ============================================================
_case_parse_status_args_invalid_output() {
    echo "=== Test: parse_status_args rejects invalid --output ==="
    (
        load_modules

        local exit_code=0
        (parse_status_args --output json) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "invalid --output rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: parse_status_args rejects unknown option
# ============================================================
_case_parse_status_unknown_option() {
    echo "=== Test: parse_status_args unknown option ==="
    (
        _load_status_ssh_test_modules

        local exit_code=0
        (parse_status_args --bogus-flag) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "unknown option rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: status --help exits 0
# ============================================================
_case_status_help_exit() {
    echo "=== Test: status --help exits 0 ==="
    _assert_exit_code "setup-k8s.sh status --help exits 0" 0 bash "$PROJECT_ROOT/setup-k8s.sh" status --help
}

# File-local module loaders
_load_status_test_modules() {
    load_modules
}

_load_status_ssh_test_modules() {
    _load_status_test_modules
}

@test "STATUS_OUTPUT_FORMAT default" {
    _case_status_output_format_default
}

@test "parse_status_args" {
    _case_parse_status_args
}

@test "parse_status_args rejects invalid --output" {
    _case_parse_status_args_invalid_output
}

@test "parse_status_args unknown option" {
    _case_parse_status_unknown_option
}

@test "status --help exits 0" {
    _case_status_help_exit
}
