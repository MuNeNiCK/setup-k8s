#!/usr/bin/env bats
# Ported from test/unit/test_ipv6.sh

setup() {
    load '../helpers/common'
}

# ============================================================
# Test: _is_ipv6 address family detection
# ============================================================
_case_is_ipv6() {
    echo "=== Test: _is_ipv6 address family detection ==="
    (
        load_modules

        local result
        _is_ipv6 "192.168.1.1" && result="true" || result="false"
        _assert_eq "_is_ipv6 IPv4 returns false" "false" "$result"

        _is_ipv6 "fd00::1" && result="true" || result="false"
        _assert_eq "_is_ipv6 IPv6 returns true" "true" "$result"

        _is_ipv6 "::1" && result="true" || result="false"
        _assert_eq "_is_ipv6 loopback returns true" "true" "$result"

        _is_ipv6 "2001:db8::1" && result="true" || result="false"
        _assert_eq "_is_ipv6 full IPv6 returns true" "true" "$result"
    )
}

# ============================================================
# Test: _validate_ipv6_addr
# ============================================================
_case_validate_ipv6_addr() {
    echo "=== Test: _validate_ipv6_addr ==="
    (
        load_modules

        # Valid addresses should pass
        local exit_code=0
        (_validate_ipv6_addr "fd00::1" "test") >/dev/null 2>&1 || exit_code=$?
        _assert_eq "valid IPv6 addr accepted" "0" "$exit_code"

        exit_code=0
        (_validate_ipv6_addr "2001:db8:85a3::8a2e:370:7334" "test") >/dev/null 2>&1 || exit_code=$?
        _assert_eq "full IPv6 addr accepted" "0" "$exit_code"

        # Invalid address should fail
        exit_code=0
        (_validate_ipv6_addr "not-an-ipv6" "test") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "invalid IPv6 addr rejected" "0" "$exit_code"

        exit_code=0
        (_validate_ipv6_addr "fd00::xyz" "test") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "IPv6 addr with invalid chars rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: _validate_cidr with IPv6 and dual-stack
# ============================================================
_case_validate_cidr_ipv6() {
    echo "=== Test: _validate_cidr IPv6/dual-stack ==="
    (
        load_modules

        # IPv4 single CIDR still works
        local exit_code=0
        (_validate_cidr "10.244.0.0/16" "test") >/dev/null 2>&1 || exit_code=$?
        _assert_eq "IPv4 single CIDR accepted" "0" "$exit_code"

        # IPv6 single CIDR
        exit_code=0
        (_validate_cidr "fd00::/48" "test") >/dev/null 2>&1 || exit_code=$?
        _assert_eq "IPv6 single CIDR accepted" "0" "$exit_code"

        # Dual-stack CIDR (IPv4 + IPv6)
        exit_code=0
        (_validate_cidr "10.244.0.0/16,fd00:10:244::/48" "test") >/dev/null 2>&1 || exit_code=$?
        _assert_eq "dual-stack CIDR accepted" "0" "$exit_code"

        # Dual-stack with two IPv4 CIDRs should fail
        exit_code=0
        (_validate_cidr "10.244.0.0/16,10.245.0.0/16" "test") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "two IPv4 CIDRs rejected" "0" "$exit_code"

        # Dual-stack with two IPv6 CIDRs should fail
        exit_code=0
        (_validate_cidr "fd00::/48,fd01::/48" "test") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "two IPv6 CIDRs rejected" "0" "$exit_code"

        # Invalid IPv6 CIDR
        exit_code=0
        (_validate_cidr "xyz::/48" "test") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "invalid IPv6 CIDR rejected" "0" "$exit_code"

        # IPv6 prefix out of range
        exit_code=0
        (_validate_cidr "fd00::/200" "test") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "IPv6 prefix >128 rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: parse_setup_args with IPv6/dual-stack CIDRs
# ============================================================
_case_parse_setup_args_ipv6() {
    echo "=== Test: parse_setup_args IPv6/dual-stack ==="
    (
        load_modules

        ACTION="init"
        parse_setup_args --pod-network-cidr "fd00:10:244::/48" --service-cidr "fd00:20::/108"
        _assert_eq "IPv6 pod CIDR parsed" "fd00:10:244::/48" "$KUBEADM_POD_CIDR"
        _assert_eq "IPv6 service CIDR parsed" "fd00:20::/108" "$KUBEADM_SERVICE_CIDR"
    )
}

_case_parse_setup_args_dual_stack() {
    echo "=== Test: parse_setup_args dual-stack ==="
    (
        load_modules

        ACTION="init"
        parse_setup_args --pod-network-cidr "10.244.0.0/16,fd00:10:244::/48" \
                         --service-cidr "10.96.0.0/12,fd00:20::/108"
        _assert_eq "dual-stack pod CIDR parsed" "10.244.0.0/16,fd00:10:244::/48" "$KUBEADM_POD_CIDR"
        _assert_eq "dual-stack service CIDR parsed" "10.96.0.0/12,fd00:20::/108" "$KUBEADM_SERVICE_CIDR"
    )
}

# ============================================================
# Test: join-address error message contains IPv6 example
# ============================================================
_case_join_address_ipv6_example() {
    echo "=== Test: join-address error message IPv6 example ==="
    (
        load_modules

        # shellcheck disable=SC2034 # used by validate_join_args
        ACTION="join"
        # shellcheck disable=SC2034 # used by validate_join_args
        JOIN_TOKEN="abcdef.1234567890abcdef"
        # shellcheck disable=SC2034 # used by validate_join_args
        DISCOVERY_TOKEN_HASH="sha256:$(printf '%064d' 0)"
        # shellcheck disable=SC2034 # used by validate_join_args
        JOIN_ADDRESS="noport"
        local err_output
        err_output=$(validate_join_args 2>&1) || true
        local has_ipv6_example="false"
        if echo "$err_output" | grep -q '\[::1\]:6443'; then has_ipv6_example="true"; fi
        _assert_eq "join error contains IPv6 example" "true" "$has_ipv6_example"
    )
}

@test "_is_ipv6 address family detection" {
    _case_is_ipv6
}

@test "_validate_ipv6_addr" {
    _case_validate_ipv6_addr
}

@test "_validate_cidr IPv6/dual-stack" {
    _case_validate_cidr_ipv6
}

@test "parse_setup_args IPv6/dual-stack" {
    _case_parse_setup_args_ipv6
}

@test "parse_setup_args dual-stack" {
    _case_parse_setup_args_dual_stack
}

@test "join-address error message IPv6 example" {
    _case_join_address_ipv6_example
}
