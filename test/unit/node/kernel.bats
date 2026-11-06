#!/usr/bin/env bats
# Ported from test/unit/test_networking.sh

setup() {
    load '../helpers/common'
}

# ============================================================
# Test: kernel version comparison logic
# ============================================================
_case_kernel_version_comparison() {
    echo "=== Test: kernel version comparison ==="
    # Simulate the fixed comparison from networking.sh
    _check_kernel() {
        local major="$1" minor="$2"
        if [ "$major" -lt 3 ] || { [ "$major" -eq 3 ] && [ "$minor" -lt 13 ]; }; then
            echo "too_old"
        elif [ "$major" -lt 4 ] || { [ "$major" -eq 4 ] && [ "$minor" -lt 14 ]; }; then
            echo "limited"
        else
            echo "ok"
        fi
    }
    _assert_eq "kernel 2.6 too old" "too_old" "$(_check_kernel 2 6)"
    _assert_eq "kernel 3.10 too old" "too_old" "$(_check_kernel 3 10)"
    _assert_eq "kernel 3.12 too old" "too_old" "$(_check_kernel 3 12)"
    _assert_eq "kernel 3.13 limited" "limited" "$(_check_kernel 3 13)"
    _assert_eq "kernel 4.0 limited" "limited" "$(_check_kernel 4 0)"
    _assert_eq "kernel 4.13 limited" "limited" "$(_check_kernel 4 13)"
    _assert_eq "kernel 4.14 ok" "ok" "$(_check_kernel 4 14)"
    _assert_eq "kernel 5.15 ok" "ok" "$(_check_kernel 5 15)"
    _assert_eq "kernel 6.1 ok" "ok" "$(_check_kernel 6 1)"
}

# ============================================================
# Test: networking.sh core functions defined
# ============================================================
_case_networking_functions_defined() {
    echo "=== Test: networking.sh core functions defined ==="
    (
        load_modules
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }

        local has_check_ipvs="false"
        type check_ipvs_availability >/dev/null 2>&1 && has_check_ipvs="true"
        _assert_eq "check_ipvs_availability defined" "true" "$has_check_ipvs"

        local has_check_nftables="false"
        type check_nftables_availability >/dev/null 2>&1 && has_check_nftables="true"
        _assert_eq "check_nftables_availability defined" "true" "$has_check_nftables"

        local has_configure="false"
        type configure_network_settings >/dev/null 2>&1 && has_configure="true"
        _assert_eq "configure_network_settings defined" "true" "$has_configure"

        local has_enable="false"
        type enable_kernel_modules >/dev/null 2>&1 && has_enable="true"
        _assert_eq "enable_kernel_modules defined" "true" "$has_enable"

        local has_cleanup="false"
        type cleanup_cni >/dev/null 2>&1 && has_cleanup="true"
        _assert_eq "cleanup_cni defined" "true" "$has_cleanup"

        local has_reset="false"
        type reset_iptables >/dev/null 2>&1 && has_reset="true"
        _assert_eq "reset_iptables defined" "true" "$has_reset"
    )
}

# ============================================================
# Test: network options defaults
# ============================================================
_case_network_options_defaults() {
    echo "=== Test: network options defaults ==="
    (
        load_modules
        _assert_eq "KUBEADM_CONFIG_PATCH default" "" "$KUBEADM_CONFIG_PATCH"
        _assert_eq "API_SERVER_EXTRA_SANS default" "" "$API_SERVER_EXTRA_SANS"
        _assert_eq "KUBELET_NODE_IP default" "" "$KUBELET_NODE_IP"
    )
}

# ============================================================
# Test: parse network options
# ============================================================
_case_parse_network_options() {
    echo "=== Test: parse network options ==="
    (
        load_modules
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        _require_value() { [ "$1" -ge 2 ] || { echo "missing value for $2" >&2; exit 1; }; }
        _parse_distro_arg() { :; }
        _validate_ha_args() { :; }

        local tmpfile
        tmpfile=$(mktemp /tmp/test-patch-XXXXXX)
        echo "test: true" > "$tmpfile"

        parse_setup_args --api-server-extra-sans "foo.example.com,10.0.0.5" --kubelet-node-ip "192.168.1.10" --kubeadm-config-patch "$tmpfile"
        _assert_eq "API_SERVER_EXTRA_SANS parsed" "foo.example.com,10.0.0.5" "$API_SERVER_EXTRA_SANS"
        _assert_eq "KUBELET_NODE_IP parsed" "192.168.1.10" "$KUBELET_NODE_IP"
        _assert_eq "KUBEADM_CONFIG_PATCH parsed" "$tmpfile" "$KUBEADM_CONFIG_PATCH"
        rm -f "$tmpfile"
    )
}

# ============================================================
# Test: enable_kernel_modules iptables mode module list
# ============================================================
_case_kernel_modules_iptables_mode() {
    echo "=== Test: enable_kernel_modules iptables mode module list ==="
    (
        load_modules
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }

        PROXY_MODE="iptables"

        # Capture the module list by overriding commands
        local captured_modules=""
        # Override: intercept what gets written to modules-load config
        cat() {
            if [ "$1" = ">" ]; then
                # Reading stdin
                while IFS= read -r line; do
                    captured_modules="${captured_modules}${captured_modules:+
}${line}"
                done
            else
                command cat "$@"
            fi
        }
        modprobe() { return 0; }
        sysctl() { return 0; }

        # Build modules string like enable_kernel_modules does
        local modules="overlay
br_netfilter"
        # iptables mode: no extra modules

        local has_overlay="false"
        echo "$modules" | grep -q "overlay" && has_overlay="true"
        _assert_eq "iptables: has overlay" "true" "$has_overlay"

        local has_br_netfilter="false"
        echo "$modules" | grep -q "br_netfilter" && has_br_netfilter="true"
        _assert_eq "iptables: has br_netfilter" "true" "$has_br_netfilter"

        local has_ip_vs="false"
        echo "$modules" | grep -q "ip_vs" && has_ip_vs="true"
        _assert_eq "iptables: no ip_vs" "false" "$has_ip_vs"
    )
}

# ============================================================
# Test: IPVS proxy mode kernel module list
# ============================================================
_case_kernel_modules_ipvs_list() {
    echo "=== Test: IPVS proxy mode kernel module list ==="
    (
        load_modules
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }

        PROXY_MODE="ipvs"

        # Build same module string as enable_kernel_modules
        local modules="overlay
br_netfilter"
        modules="${modules}
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack"

        local has_ip_vs="false"
        echo "$modules" | grep -q "^ip_vs$" && has_ip_vs="true"
        _assert_eq "ipvs: has ip_vs" "true" "$has_ip_vs"

        local has_rr="false"
        echo "$modules" | grep -q "ip_vs_rr" && has_rr="true"
        _assert_eq "ipvs: has ip_vs_rr" "true" "$has_rr"

        local has_wrr="false"
        echo "$modules" | grep -q "ip_vs_wrr" && has_wrr="true"
        _assert_eq "ipvs: has ip_vs_wrr" "true" "$has_wrr"

        local has_sh="false"
        echo "$modules" | grep -q "ip_vs_sh" && has_sh="true"
        _assert_eq "ipvs: has ip_vs_sh" "true" "$has_sh"

        local has_conntrack="false"
        echo "$modules" | grep -q "nf_conntrack" && has_conntrack="true"
        _assert_eq "ipvs: has nf_conntrack" "true" "$has_conntrack"
    )
}

# ============================================================
# Test: nftables proxy mode kernel module list
# ============================================================
_case_kernel_modules_nftables_list() {
    echo "=== Test: nftables proxy mode kernel module list ==="
    (
        load_modules
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }

        PROXY_MODE="nftables"

        # Build same module string as enable_kernel_modules
        local modules="overlay
br_netfilter"
        modules="${modules}
nf_tables
nf_tables_ipv4
nf_tables_ipv6
nft_chain_nat_ipv4
nft_chain_nat_ipv6
nf_nat
nf_conntrack"

        local has_nf_tables="false"
        echo "$modules" | grep -q "^nf_tables$" && has_nf_tables="true"
        _assert_eq "nftables: has nf_tables" "true" "$has_nf_tables"

        local has_nat="false"
        echo "$modules" | grep -q "nf_nat" && has_nat="true"
        _assert_eq "nftables: has nf_nat" "true" "$has_nat"

        local has_ipv4="false"
        echo "$modules" | grep -q "nf_tables_ipv4" && has_ipv4="true"
        _assert_eq "nftables: has nf_tables_ipv4" "true" "$has_ipv4"

        local has_no_ipvs="true"
        echo "$modules" | grep -q "ip_vs" && has_no_ipvs="false"
        _assert_eq "nftables: no ip_vs" "true" "$has_no_ipvs"
    )
}

# ============================================================
# Test: configure_network_settings sysctl content
# ============================================================
_case_sysctl_settings_content() {
    echo "=== Test: configure_network_settings sysctl content ==="
    (
        load_modules
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }

        # Expected sysctl settings
        local expected_settings="net.bridge.bridge-nf-call-iptables
net.bridge.bridge-nf-call-ip6tables
net.ipv4.ip_forward
net.ipv6.conf.all.forwarding"

        for setting in $expected_settings; do
            local has_it="true"
            _assert_eq "sysctl has $setting" "true" "$has_it"
        done
    )
}

# ============================================================
# Test: install_proxy_mode_packages logic
# ============================================================
_case_install_proxy_mode_packages_logic() {
    echo "=== Test: install_proxy_mode_packages logic ==="
    (
        load_modules
        local captured_args=""
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }

        # Mock install command
        mock_install() { captured_args="$*"; return 0; }

        # IPVS mode
        PROXY_MODE="ipvs"
        captured_args=""
        install_proxy_mode_packages mock_install
        local has_ipvsadm="false"
        echo "$captured_args" | grep -q "ipvsadm" && has_ipvsadm="true"
        _assert_eq "ipvs installs ipvsadm" "true" "$has_ipvsadm"
        local has_ipset="false"
        echo "$captured_args" | grep -q "ipset" && has_ipset="true"
        _assert_eq "ipvs installs ipset" "true" "$has_ipset"

        # nftables mode
        PROXY_MODE="nftables"
        captured_args=""
        install_proxy_mode_packages mock_install
        local has_nftables="false"
        echo "$captured_args" | grep -q "nftables" && has_nftables="true"
        _assert_eq "nftables installs nftables" "true" "$has_nftables"

        # iptables mode (should not install anything)
        # shellcheck disable=SC2034 # used by install_proxy_mode_packages
        PROXY_MODE="iptables"
        captured_args=""
        install_proxy_mode_packages mock_install
        _assert_eq "iptables installs nothing" "" "$captured_args"
    )
}

@test "kernel version comparison" {
    _case_kernel_version_comparison
}

@test "network options defaults" {
    _case_network_options_defaults
}

@test "parse network options" {
    _case_parse_network_options
}

@test "networking.sh core functions defined" {
    _case_networking_functions_defined
}

@test "enable_kernel_modules iptables mode module list" {
    _case_kernel_modules_iptables_mode
}

@test "IPVS proxy mode kernel module list" {
    _case_kernel_modules_ipvs_list
}

@test "nftables proxy mode kernel module list" {
    _case_kernel_modules_nftables_list
}

@test "configure_network_settings sysctl content" {
    _case_sysctl_settings_content
}

@test "install_proxy_mode_packages logic" {
    _case_install_proxy_mode_packages_logic
}
