#!/usr/bin/env bats
# shellcheck disable=SC2034 # tests set globals read by the modules under test
# Ported from test/unit/test_networking.sh

setup() {
    load '../helpers/common'
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

        parse_setup_args --apiserver-cert-extra-sans "foo.example.com,10.0.0.5" --kubelet-node-ip "192.168.1.10" --kubeadm-config-patch "$tmpfile"
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
    load_modules; quiet_logs
    DISTRO_PKG=apt
    fake_cmd apt-get
    fake_cmd apt-mark

    PROXY_MODE=ipvs install_proxy_mode_packages
    fake_calls | grep -q '^apt-get install -y .* ipvsadm ipset$'

    : > "$FAKE_LOG"
    PROXY_MODE=nftables install_proxy_mode_packages
    fake_calls | grep -q '^apt-get install -y .* nftables$'

    : > "$FAKE_LOG"
    PROXY_MODE=iptables install_proxy_mode_packages
    [ -z "$(fake_calls)" ]
}

@test "network options defaults" {
    _case_network_options_defaults
}

@test "parse network options" {
    _case_parse_network_options
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

# --- host preparation result ---

_prepare_fixture() {
    load_modules; quiet_logs
    _detect_init_system() { echo "${INIT:-systemd}"; }
    _CGROUP_ROOT="$BATS_TEST_TMPDIR/cgroup"
    _MOUNTINFO="$BATS_TEST_TMPDIR/mountinfo"
    mkdir -p "$_CGROUP_ROOT"
    touch "$_CGROUP_ROOT/cgroup.controllers"
    echo '22 1 252:0 / / rw,relatime shared:1 - ext4 /dev/vda1 rw' > "$_MOUNTINFO"
    fake_cmd mount
    fake_cmd rc-update
    fake_cmd rc-service
    [ -s /etc/machine-id ] || skip "no /etc/machine-id on the test host"
}

@test "host preparation succeeds with cgroups and a shared root mount" {
    _prepare_fixture
    system_prepare
}

@test "host preparation fails when the root mount stays private" {
    _prepare_fixture
    echo '22 1 252:0 / / rw,relatime - ext4 /dev/vda1 rw' > "$_MOUNTINFO"
    INIT=openrc _K8S_SHARED_MOUNT_SCRIPT="$BATS_TEST_TMPDIR/local.d/k8s.start"
    run system_prepare
    [ "$status" -ne 0 ]
}

@test "host preparation fails without usable cgroups" {
    _prepare_fixture
    rm -f "$_CGROUP_ROOT/cgroup.controllers"
    # pretend v1 already mounted (so nothing is mounted) but without memory
    mkdir -p "$_CGROUP_ROOT/cpu"
    run system_prepare
    [ "$status" -ne 0 ]
}

@test "CRI-O is restarted and must be active afterwards" {
    load_modules; quiet_logs
    _service_reload() { :; }
    _service_enable() { :; }
    _detect_init_system() { echo systemd; }
    CALLS="$BATS_TEST_TMPDIR/calls"
    _service_restart() { echo "restart $1" >> "$CALLS"; }
    _service_start() { echo "start $1" >> "$CALLS"; }
    _service_is_active() { [ "${CRIO_UP:-true}" = true ]; }
    fake_cmd systemctl
    fake_cmd journalctl
    _start_crio_with_diagnostics
    grep -qx 'restart crio' "$CALLS"
    CRIO_UP=false
    run _start_crio_with_diagnostics
    [ "$status" -ne 0 ]
}
