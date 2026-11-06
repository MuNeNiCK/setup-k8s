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
# Test: _build_join_cmd
# ============================================================
_case_build_join_cmd() {
    echo "=== Test: _build_join_cmd ==="
    (
        _load_deploy_test_modules

        _JOIN_TOKEN="abcdef.0123456789abcdef"
        _JOIN_ADDR="10.0.0.1:6443"
        _JOIN_HASH="sha256:abc123"

        local result
        result=$(_build_join_cmd "sudo " "/tmp/setup-k8s.sh")

        local has_join="false"
        echo "$result" | grep -q "sudo sh /tmp/setup-k8s.sh join" && has_join="true"
        _assert_eq "build_join_cmd has sudo+join" "true" "$has_join"

        local has_token="false"
        echo "$result" | grep -q "join-token" && has_token="true"
        _assert_eq "build_join_cmd has token" "true" "$has_token"

        local has_addr="false"
        echo "$result" | grep -q "join-address" && has_addr="true"
        _assert_eq "build_join_cmd has address" "true" "$has_addr"

        local has_hash="false"
        echo "$result" | grep -q "discovery-token-hash" && has_hash="true"
        _assert_eq "build_join_cmd has hash" "true" "$has_hash"

        # Without sudo
        result=$(_build_join_cmd "" "/tmp/setup-k8s.sh")
        local has_nosudo="false"
        echo "$result" | grep -q "^sh /tmp/setup-k8s.sh join" && has_nosudo="true"
        _assert_eq "build_join_cmd no sudo" "true" "$has_nosudo"
    )
}

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

@test "_build_join_cmd" {
    _case_build_join_cmd
}

@test "DEPLOY_REMOTE_TIMEOUT / DEPLOY_POLL_INTERVAL defaults" {
    _case_deploy_timeout_defaults
}
