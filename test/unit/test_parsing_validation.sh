#!/bin/sh
# Unit tests for argument parsing, validation, help output, proxy mode, and pipefail

# File-local module loader (avoids repeating source blocks in every test)
_load_validation_test_modules() {
    source "$PROJECT_ROOT/lib/variables.sh"
    source "$PROJECT_ROOT/lib/logging.sh"
    source "$PROJECT_ROOT/lib/validation.sh"
}

# ============================================================
# Test: parse_setup_args
# ============================================================
test_parse_setup_args() {
    echo "=== Test: parse_setup_args ==="
    (
        source "$PROJECT_ROOT/lib/variables.sh"
        source "$PROJECT_ROOT/lib/validation.sh"
        source "$PROJECT_ROOT/commands/init.sh"

        ACTION="join"
        parse_setup_args --cri crio --kubernetes-version 1.31 \
            --join-token abc --join-address 1.2.3.4:6443 \
            --discovery-token-hash sha256:xyz \
            --proxy-mode ipvs --install-helm true --install-kustomize true \
            --pod-network-cidr 10.244.0.0/16 --service-cidr 10.96.0.0/12

        _assert_eq "ACTION" "join" "$ACTION"
        _assert_eq "CRI parsed" "crio" "$CRI"
        _assert_eq "K8S_VERSION parsed" "1.31" "$K8S_VERSION"
        _assert_eq "JOIN_TOKEN parsed" "abc" "$JOIN_TOKEN"
        _assert_eq "JOIN_ADDRESS parsed" "1.2.3.4:6443" "$JOIN_ADDRESS"
        _assert_eq "PROXY_MODE parsed" "ipvs" "$PROXY_MODE"
        _assert_eq "INSTALL_HELM parsed" "true" "$INSTALL_HELM"
        _assert_eq "INSTALL_KUSTOMIZE parsed" "true" "$INSTALL_KUSTOMIZE"
        _assert_eq "KUBEADM_POD_CIDR parsed" "10.244.0.0/16" "$KUBEADM_POD_CIDR"
        _assert_eq "KUBEADM_SERVICE_CIDR parsed" "10.96.0.0/12" "$KUBEADM_SERVICE_CIDR"
    )
}

# ============================================================
# Test: _require_value catches missing arguments
# ============================================================
test_require_value() {
    echo "=== Test: _require_value argument guard ==="
    (
        _load_validation_test_modules

        # Simulating $# = 1 (only the flag, no value)
        local exit_code=0
        (_require_value 1 "--cri") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "_require_value rejects missing value" "0" "$exit_code"

        # Simulating $# = 2 (flag + value present)
        exit_code=0
        (_require_value 2 "--cri") >/dev/null 2>&1 || exit_code=$?
        _assert_eq "_require_value accepts present value" "0" "$exit_code"
    )
}

# ============================================================
# Test: unknown option exits with non-zero
# ============================================================
test_unknown_option_exit_code() {
    echo "=== Test: unknown option exit code ==="
    (
        source "$PROJECT_ROOT/lib/variables.sh"
        source "$PROJECT_ROOT/lib/validation.sh"
        source "$PROJECT_ROOT/lib/helpers.sh"
        source "$PROJECT_ROOT/commands/init.sh"
        source "$PROJECT_ROOT/commands/cleanup.sh"

        local exit_code=0
        ACTION="init"
        (parse_setup_args --bogus-flag) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "parse_setup_args rejects unknown option" "0" "$exit_code"

        exit_code=0
        (parse_cleanup_args --bogus-flag) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "parse_cleanup_args rejects unknown option" "0" "$exit_code"
    )
}

# ============================================================
# Test: --help early exit (no module download)
# ============================================================
test_help_early_exit() {
    echo "=== Test: --help early exit ==="
    _assert_exit_code "setup-k8s.sh --help exits 0" 0 bash "$PROJECT_ROOT/setup-k8s.sh" --help
}

# ============================================================
# Test: validate_proxy_mode nftables version check
# ============================================================
test_validate_proxy_mode() {
    echo "=== Test: validate_proxy_mode ==="
    (
        _load_validation_test_modules

        # iptables should always pass
        PROXY_MODE="iptables"
        K8S_VERSION="1.28"
        validate_proxy_mode
        _assert_eq "iptables mode passes" "iptables" "$PROXY_MODE"

        # nftables with old version should fail (run in nested subshell
        # because validate_proxy_mode uses exit, not return)
        PROXY_MODE="nftables"
        K8S_VERSION="1.28"
        local exit_code=0
        (validate_proxy_mode) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "nftables 1.28 rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: pipefail safety — awk pipelines must survive zero matches
# ============================================================
test_pipefail_safety() {
    echo "=== Test: pipefail safety (awk vs grep under set -euo pipefail) ==="

    # networking.sh: nft list tables | awk ... | while read
    # Simulate empty input (no k8s-related nft tables)
    _assert_exit_code "nft awk pipeline (no match)" 0 \
        bash -c "set -euo pipefail; echo '' | awk '/kube-proxy|kubernetes/ {print \$2, \$3}' | while read -r family name; do echo \"\$family \$name\"; done"

    # debian/kubernetes.sh: apt-cache madison | awk -v ver=...
    # Simulate no matching version
    _assert_exit_code "apt-cache awk pipeline (no match)" 0 \
        bash -c "set -euo pipefail; echo 'kubeadm | 1.30.0-1.1 | https://pkgs.k8s.io' | awk -v ver='9.99.' 'index(\$0, ver) {print \$3; exit}'"

    # debian/kubernetes.sh: awk early exit with large input must not SIGPIPE
    # Simulates apt-cache madison producing many lines; awk exits after first match
    _assert_exit_code "awk early exit on large input (no SIGPIPE)" 0 \
        bash -c "set -euo pipefail; madison_out=\$(seq 1 1000 | sed 's/^/kubeadm | 1.32./'); echo \"\$madison_out\" | awk -v ver='1.32.' 'index(\$0, ver) {print \$3; exit}'"

    # Same pattern but piped directly — would SIGPIPE under pipefail
    # Exit code varies by environment (141 locally, 1 on some CI), so just assert non-zero
    local sigpipe_exit=0
    bash -c 'set -euo pipefail; seq 1 100000 | awk "{print; exit}"' >/dev/null 2>&1 || sigpipe_exit=$?
    _assert_ne "direct pipe awk early exit SIGPIPE (sanity check)" "0" "$sigpipe_exit"

    # Negative test: confirm grep WOULD fail under pipefail
    _assert_exit_code "grep pipeline fails under pipefail (sanity check)" 1 \
        bash -c 'set -euo pipefail; echo "no-match" | grep "NOTFOUND" | head -1'
}

# ============================================================
# Test: --swap-enabled in help text
# ============================================================
test_help_contains_swap() {
    echo "=== Test: help text contains --swap-enabled ==="
    (
        local help_out
        help_out=$(bash "$PROJECT_ROOT/setup-k8s.sh" --help 2>&1)
        local has_swap="false"
        if echo "$help_out" | grep -q -- '--swap-enabled'; then has_swap="true"; fi
        _assert_eq "help contains --swap-enabled" "true" "$has_swap"
    )
}

# ============================================================
# Test: help text contains 'upgrade'
# ============================================================
test_help_contains_upgrade() {
    echo "=== Test: help text contains upgrade ==="
    (
        local help_out
        help_out=$(bash "$PROJECT_ROOT/setup-k8s.sh" --help 2>&1)
        local has_upgrade="false"
        if echo "$help_out" | grep -q 'upgrade'; then has_upgrade="true"; fi
        _assert_eq "help contains upgrade" "true" "$has_upgrade"
    )
}

# ============================================================
# Test: validate_join_args
# ============================================================
test_validate_join_args() {
    echo "=== Test: validate_join_args ==="
    (
        _load_validation_test_modules

        # Valid join args should pass
        ACTION="join"
        JOIN_TOKEN="abcdef.1234567890abcdef"
        JOIN_ADDRESS="10.0.0.1:6443"
        DISCOVERY_TOKEN_HASH="sha256:$(printf '%064d' 0)"
        validate_join_args
        _assert_eq "valid join args pass" "join" "$ACTION"

        # Missing token should fail
        local exit_code=0
        (
            ACTION="join"
            JOIN_TOKEN=""
            JOIN_ADDRESS="10.0.0.1:6443"
            DISCOVERY_TOKEN_HASH="sha256:$(printf '%064d' 0)"
            validate_join_args
        ) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "missing token rejected" "0" "$exit_code"

        # Bad token format should fail
        exit_code=0
        (
            ACTION="join"
            JOIN_TOKEN="bad-token"
            JOIN_ADDRESS="10.0.0.1:6443"
            DISCOVERY_TOKEN_HASH="sha256:$(printf '%064d' 0)"
            validate_join_args
        ) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "bad token format rejected" "0" "$exit_code"

        # Address without port should fail
        exit_code=0
        (
            ACTION="join"
            JOIN_TOKEN="abcdef.1234567890abcdef"
            JOIN_ADDRESS="10.0.0.1"
            DISCOVERY_TOKEN_HASH="sha256:$(printf '%064d' 0)"
            validate_join_args
        ) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "address without port rejected" "0" "$exit_code"

        # init action should skip validation
        ACTION="init"
        JOIN_TOKEN=""
        JOIN_ADDRESS=""
        # shellcheck disable=SC2034 # used by validate_join_args
        DISCOVERY_TOKEN_HASH=""
        validate_join_args
        _assert_eq "init action skips validation" "init" "$ACTION"
    )
}

# ============================================================
# Test: validate_cri
# ============================================================
test_validate_cri() {
    echo "=== Test: validate_cri ==="
    (
        _load_validation_test_modules

        CRI="containerd"
        validate_cri
        _assert_eq "containerd passes" "containerd" "$CRI"

        CRI="crio"
        validate_cri
        _assert_eq "crio passes" "crio" "$CRI"

        local exit_code=0
        (CRI="docker"; validate_cri) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "docker rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: _normalize_node_list
# ============================================================
test_normalize_node_list() {
    echo "=== Test: _normalize_node_list ==="
    (
        source "$PROJECT_ROOT/lib/variables.sh"
        source "$PROJECT_ROOT/lib/validation.sh"
        source "$PROJECT_ROOT/lib/ssh_args.sh"
        source "$PROJECT_ROOT/lib/ssh.sh"
        source "$PROJECT_ROOT/lib/ssh_session.sh"

        local result
        result=$(_normalize_node_list " node1 , node2,,node3 ")
        _assert_eq "trims and deduplicates empty tokens" "node1,node2,node3" "$result"

        result=$(_normalize_node_list "single")
        _assert_eq "single node unchanged" "single" "$result"

        result=$(_normalize_node_list ",,")
        _assert_eq "all empty tokens gives empty" "" "$result"
    )
}

# ============================================================
# Test: _validate_node_addresses
# ============================================================
test_validate_node_addresses() {
    echo "=== Test: _validate_node_addresses ==="
    (
        source "$PROJECT_ROOT/lib/bootstrap.sh" >/dev/null 2>&1 || true
        source "$PROJECT_ROOT/lib/variables.sh"
        source "$PROJECT_ROOT/lib/validation.sh"
        source "$PROJECT_ROOT/lib/helpers.sh"
        source "$PROJECT_ROOT/lib/ssh_args.sh"
        source "$PROJECT_ROOT/lib/ssh.sh"
        source "$PROJECT_ROOT/lib/ssh_session.sh"
        source "$PROJECT_ROOT/commands/upgrade.sh"

        # Valid addresses should pass
        local exit_code=0
        (_validate_node_addresses "10.0.0.1,admin@10.0.0.2") >/dev/null 2>&1 || exit_code=$?
        _assert_eq "valid addresses pass" "0" "$exit_code"

        # Duplicate address should fail
        exit_code=0
        (_validate_node_addresses "10.0.0.1,10.0.0.1") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "duplicate address rejected" "0" "$exit_code"

        # Bare IPv6 without brackets should fail
        exit_code=0
        (_validate_node_addresses "fd00::1") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "bare IPv6 rejected" "0" "$exit_code"

        # Bracketed IPv6 should pass
        exit_code=0
        (_validate_node_addresses "[fd00::1]") >/dev/null 2>&1 || exit_code=$?
        _assert_eq "bracketed IPv6 passes" "0" "$exit_code"

        # Username starting with - should fail
        exit_code=0
        (_validate_node_addresses "-evil@10.0.0.1") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "dash username rejected" "0" "$exit_code"
    )
}
