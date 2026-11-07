#!/usr/bin/env bats
# Ported from test/unit/test_kubevip_ha.sh

setup() {
    load '../helpers/common'
}

# ============================================================
# Test: parse_setup_args HA cluster flags
# ============================================================
_case_parse_ha_args() {
    echo "=== Test: parse_setup_args HA cluster flags ==="
    (
        load_modules

        ACTION="join"
        parse_setup_args --control-plane --certificate-key mykey123 \
            --token abc --join-address 1.2.3.4:6443 --discovery-token-ca-cert-hash sha256:xyz

        _assert_eq "JOIN_AS_CONTROL_PLANE" "true" "$JOIN_AS_CONTROL_PLANE"
        _assert_eq "CERTIFICATE_KEY" "mykey123" "$CERTIFICATE_KEY"
    )
}

# ============================================================
# Test: parse_setup_args HA kube-vip flags
# ============================================================
_case_parse_ha_kube_vip_args() {
    echo "=== Test: parse_setup_args HA kube-vip flags ==="
    (
        load_modules

        ACTION="init"
        parse_setup_args --ha --ha-vip 192.168.1.100 --ha-interface eth0

        _assert_eq "HA_ENABLED" "true" "$HA_ENABLED"
        _assert_eq "HA_VIP_ADDRESS" "192.168.1.100" "$HA_VIP_ADDRESS"
        _assert_eq "HA_VIP_INTERFACE" "eth0" "$HA_VIP_INTERFACE"
    )
}

# ============================================================
# Test: _kube_vip_kubeconfig_path version guard
# ============================================================
_case_kube_vip_kubeconfig_path() {
    echo "=== Test: _kube_vip_kubeconfig_path version guard ==="
    (
        load_modules

        K8S_VERSION="1.35"
        _assert_eq "K8s 1.35 uses super-admin.conf" \
            "/etc/kubernetes/super-admin.conf" "$(_kube_vip_kubeconfig_path)"

        K8S_VERSION="1.29"
        _assert_eq "K8s 1.29 uses super-admin.conf" \
            "/etc/kubernetes/super-admin.conf" "$(_kube_vip_kubeconfig_path)"

        K8S_VERSION="1.28"
        _assert_eq "K8s 1.28 uses admin.conf" \
            "/etc/kubernetes/admin.conf" "$(_kube_vip_kubeconfig_path)"

        K8S_VERSION="1.27"
        _assert_eq "K8s 1.27 uses admin.conf" \
            "/etc/kubernetes/admin.conf" "$(_kube_vip_kubeconfig_path)"

        # shellcheck disable=SC2034 # used by _kube_vip_kubeconfig_path
        K8S_VERSION=""
        _assert_eq "empty version uses admin.conf" \
            "/etc/kubernetes/admin.conf" "$(_kube_vip_kubeconfig_path)"
    )
}

# ============================================================
# Test: _generate_kube_vip_manifest produces valid YAML
# ============================================================
_case_generate_kube_vip_manifest() {
    echo "=== Test: _generate_kube_vip_manifest ==="
    (
        load_modules

        local manifest
        manifest=$(_generate_kube_vip_manifest "10.0.0.100" "eth0" "ghcr.io/kube-vip/kube-vip:v1.3.1" "/etc/kubernetes/super-admin.conf")

        local has_vip="false"
        if echo "$manifest" | grep -q 'value: "10.0.0.100"'; then has_vip="true"; fi
        _assert_eq "manifest contains VIP" "true" "$has_vip"

        local has_iface="false"
        if echo "$manifest" | grep -q 'value: "eth0"'; then has_iface="true"; fi
        _assert_eq "manifest contains interface" "true" "$has_iface"

        local has_kubeconfig="false"
        if echo "$manifest" | grep -q 'path: /etc/kubernetes/super-admin.conf'; then has_kubeconfig="true"; fi
        _assert_eq "manifest contains kubeconfig path" "true" "$has_kubeconfig"

        local has_image="false"
        if echo "$manifest" | grep -q 'image: ghcr.io/kube-vip/kube-vip:v1.3.1'; then has_image="true"; fi
        _assert_eq "manifest contains image" "true" "$has_image"
    )
}

# ============================================================
# Test: validate_ha_args for join --control-plane with --ha-vip
# ============================================================
_case_validate_ha_join_cp() {
    echo "=== Test: validate_ha_args join --control-plane ==="
    (
        load_modules

        # join --control-plane with --ha-vip should pass (interface auto-detect may fail,
        # so provide it explicitly)
        ACTION="join"
        JOIN_AS_CONTROL_PLANE=true
        HA_VIP_ADDRESS="10.0.0.100"
        HA_VIP_INTERFACE="eth0"
        validate_ha_args
        _assert_eq "join CP with ha-vip passes" "10.0.0.100" "$HA_VIP_ADDRESS"

        # join worker with --ha-vip should fail
        ACTION="join"
        JOIN_AS_CONTROL_PLANE=false
        HA_VIP_ADDRESS="10.0.0.100"
        HA_VIP_INTERFACE="eth0"
        local exit_code=0
        (validate_ha_args) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "join worker with ha-vip rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: validate_ha_args with IPv6 VIP
# ============================================================
_case_validate_ha_args_ipv6() {
    echo "=== Test: validate_ha_args IPv6 VIP ==="
    (
        load_modules

        # IPv6 VIP with explicit interface should pass
        ACTION="join"
        JOIN_AS_CONTROL_PLANE=true
        HA_VIP_ADDRESS="fd00::100"
        HA_VIP_INTERFACE="eth0"
        validate_ha_args
        _assert_eq "IPv6 VIP accepted" "fd00::100" "$HA_VIP_ADDRESS"

        # IPv6 VIP on init should set bracketed CP endpoint
        # shellcheck disable=SC2034 # globals used by validate_ha_args
        ACTION="init"
        HA_ENABLED=true
        HA_VIP_ADDRESS="fd00::100"
        HA_VIP_INTERFACE="eth0"
        KUBEADM_CP_ENDPOINT=""
        validate_ha_args
        _assert_eq "IPv6 CP endpoint bracketed" "[fd00::100]:6443" "$KUBEADM_CP_ENDPOINT"
    )
}

# ============================================================
# Test: _generate_kube_vip_manifest IPv6 VIP cidr
# ============================================================
_case_generate_kube_vip_manifest_ipv6() {
    echo "=== Test: _generate_kube_vip_manifest IPv6 ==="
    (
        load_modules

        local manifest
        manifest=$(_generate_kube_vip_manifest "fd00::100" "eth0" "ghcr.io/kube-vip/kube-vip:v1.3.1" "/etc/kubernetes/super-admin.conf")

        local has_cidr_128="false"
        if echo "$manifest" | grep -A1 -- '- name: vip_subnet' | grep -q 'value: "128"'; then has_cidr_128="true"; fi
        _assert_eq "IPv6 manifest has vip_subnet 128" "true" "$has_cidr_128"

        local has_vip="false"
        if echo "$manifest" | grep -q 'value: "fd00::100"'; then has_vip="true"; fi
        _assert_eq "IPv6 manifest contains VIP" "true" "$has_vip"

        # IPv4 should still get cidr 32
        manifest=$(_generate_kube_vip_manifest "10.0.0.100" "eth0" "ghcr.io/kube-vip/kube-vip:v1.3.1" "/etc/kubernetes/super-admin.conf")
        local has_cidr_32="false"
        if echo "$manifest" | grep -A1 -- '- name: vip_subnet' | grep -q 'value: "32"'; then has_cidr_32="true"; fi
        _assert_eq "IPv4 manifest has vip_subnet 32" "true" "$has_cidr_32"

        # kube-vip v1 reads the node name from vip_nodename
        echo "$manifest" | grep -A3 -- '- name: vip_nodename' | grep -q 'fieldPath: spec.nodeName'
    )
}

@test "parse_setup_args HA cluster flags" {
    _case_parse_ha_args
}

@test "parse_setup_args HA kube-vip flags" {
    _case_parse_ha_kube_vip_args
}

@test "_kube_vip_kubeconfig_path version guard" {
    _case_kube_vip_kubeconfig_path
}

@test "_generate_kube_vip_manifest" {
    _case_generate_kube_vip_manifest
}

@test "validate_ha_args join --control-plane" {
    _case_validate_ha_join_cp
}

@test "validate_ha_args IPv6 VIP" {
    _case_validate_ha_args_ipv6
}

@test "_generate_kube_vip_manifest IPv6" {
    _case_generate_kube_vip_manifest_ipv6
}

@test "cleanup releases the VIP named in the kube-vip manifest" {
    load_modules; quiet_logs
    manifest="$BATS_TEST_TMPDIR/kube-vip.yaml"
    _generate_kube_vip_manifest 10.0.0.100 eth0 ghcr.io/kube-vip/kube-vip:v1.3.1 /etc/kubernetes/admin.conf > "$manifest"
    fake_cmd ip 0 "    inet 10.0.0.100/32 scope global eth0"
    kube_vip_release "$manifest"
    fake_calls | grep -qx 'ip addr del 10.0.0.100/32 dev eth0'
    # Not assigned: nothing to remove
    : > "$FAKE_LOG"
    fake_cmd ip 0 "    inet 10.0.0.10/24 scope global eth0"
    kube_vip_release "$manifest"
    if fake_calls | grep -q 'addr del'; then return 1; fi
}

@test "the kube-vip image pull is retried and fails after three attempts" {
    load_modules; quiet_logs
    sleep() { :; }
    TRIES="$BATS_TEST_TMPDIR/tries"; : > "$TRIES"
    puller() { echo x >> "$TRIES"; [ "$(wc -l < "$TRIES")" -ge "${OK_AT:-99}" ]; }
    OK_AT=2 _kube_vip_pull puller
    : > "$TRIES"
    run _kube_vip_pull puller
    [ "$status" -ne 0 ]
    [ "$(wc -l < "$TRIES")" -eq 3 ]
}
