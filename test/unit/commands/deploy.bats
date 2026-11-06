#!/usr/bin/env bats
# Ported from test/unit/test_deploy.sh

setup() {
    load '../helpers/common'
}

# File-local module loader
_load_deploy_test_modules() {
    load_modules
}

# ============================================================
# Test: --swap-enabled deploy passthrough
# ============================================================
_case_deploy_parse_swap_enabled() {
    echo "=== Test: parse_deploy_args --swap-enabled passthrough ==="
    (
        _load_deploy_test_modules

        parse_deploy_args --control-planes 10.0.0.1 --swap-enabled
        local has_swap="false"
        for arg in "${DEPLOY_PASSTHROUGH_ARGS[@]}"; do
            if [ "$arg" = "--swap-enabled" ]; then has_swap="true"; break; fi
        done
        _assert_eq "swap-enabled in passthrough" "true" "$has_swap"
    )
}

# ============================================================
# Test: _download_binary fails on invalid URL
# ============================================================
_case_download_binary_failure() {
    echo "=== Test: _download_binary fails on invalid URL ==="
    (
        load_modules

        local exit_code=0
        local tmp
        tmp=$(mktemp -t test-dl-XXXXXX)
        (_download_binary "https://invalid.example.com/nonexistent" "$tmp") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "_download_binary fails on invalid URL" "0" "$exit_code"
        rm -f "$tmp"
    )
}

# ============================================================
# Test: DEPLOY_REMOTE_TIMEOUT / DEPLOY_POLL_INTERVAL defaults
# ============================================================
# ============================================================
# Test: DEPLOY_REMOTE_TIMEOUT / DEPLOY_POLL_INTERVAL defaults
# ============================================================
_case_deploy_timeout_defaults() {
    echo "=== Test: DEPLOY_REMOTE_TIMEOUT / DEPLOY_POLL_INTERVAL defaults ==="
    (
        load_modules
        _assert_eq "DEPLOY_REMOTE_TIMEOUT default" "600" "$DEPLOY_REMOTE_TIMEOUT"
        _assert_eq "DEPLOY_POLL_INTERVAL default" "10" "$DEPLOY_POLL_INTERVAL"
    )
}

@test "parse_deploy_args --swap-enabled passthrough" {
    _case_deploy_parse_swap_enabled
}

@test "_download_binary fails on invalid URL" {
    _case_download_binary_failure
}

@test "DEPLOY_REMOTE_TIMEOUT / DEPLOY_POLL_INTERVAL defaults" {
    _case_deploy_timeout_defaults
}
