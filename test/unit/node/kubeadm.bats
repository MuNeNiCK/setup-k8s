#!/usr/bin/env bats
# shellcheck disable=SC2034 # tests set globals read by the modules under test
# Ported from test/unit/test_kubeadm.sh

setup() {
    load '../helpers/common'
}

# ============================================================
# Test: generate_kubeadm_config with extra SANs
# ============================================================
_case_generate_kubeadm_config_extra_sans() {
    echo "=== Test: generate_kubeadm_config with extra SANs ==="
    (
        load_modules
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        _kubeadm_api_version() { echo "kubeadm.k8s.io/v1beta4"; }
        _kubeproxy_api_version() { echo "kubeproxy.config.k8s.io/v1alpha1"; }
        _kubelet_api_version() { echo "kubelet.config.k8s.io/v1beta1"; }
        get_cri_socket() { echo "unix:///run/containerd/containerd.sock"; }

        KUBEADM_POD_CIDR=""
        KUBEADM_SERVICE_CIDR=""
        KUBEADM_API_ADDR=""
        KUBEADM_CP_ENDPOINT=""
        API_SERVER_EXTRA_SANS="lb.example.com,10.0.0.100"
        KUBEADM_CONFIG_PATCH=""

        local config_file
        config_file=$(generate_kubeadm_config)
        local content
        content=$(cat "$config_file")
        rm -f "$config_file"

        local has_san1="false"
        echo "$content" | grep -q "lb.example.com" && has_san1="true"
        _assert_eq "extra SAN lb.example.com in config" "true" "$has_san1"

        local has_san2="false"
        echo "$content" | grep -q "10.0.0.100" && has_san2="true"
        _assert_eq "extra SAN 10.0.0.100 in config" "true" "$has_san2"

        local has_certsans="false"
        echo "$content" | grep -q "certSANs:" && has_certsans="true"
        _assert_eq "certSANs section in config" "true" "$has_certsans"
    )
}

# ============================================================
# Test: generate_kubeadm_config quotes IPv6 literals
# ============================================================
_case_generate_kubeadm_config_ipv6_literals() {
    echo "=== Test: generate_kubeadm_config quotes IPv6 literals ==="
    (
        load_modules
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        _kubeadm_api_version() { echo "kubeadm.k8s.io/v1beta4"; }
        _kubeproxy_api_version() { echo "kubeproxy.config.k8s.io/v1alpha1"; }
        _kubelet_api_version() { echo "kubelet.config.k8s.io/v1beta1"; }
        get_cri_socket() { echo "unix:///run/containerd/containerd.sock"; }

        KUBEADM_POD_CIDR="fd00:10:244::/48"
        KUBEADM_SERVICE_CIDR="fd00:20::/108"
        KUBEADM_API_ADDR="fd00:10:2::15"
        KUBEADM_CP_ENDPOINT="[fd00:10:2::15]:6443"
        API_SERVER_EXTRA_SANS="setup-k8s.local,fd00:10:2::15"
        KUBEADM_CONFIG_PATCH=""

        local config_file
        config_file=$(generate_kubeadm_config)
        local content
        content=$(cat "$config_file")
        rm -f "$config_file"

        echo "$content" | grep -q "advertiseAddress: 'fd00:10:2::15'"
        _assert_eq "IPv6 advertiseAddress quoted" "0" "$?"

        echo "$content" | grep -q "controlPlaneEndpoint: '\\[fd00:10:2::15\\]:6443'"
        _assert_eq "IPv6 controlPlaneEndpoint quoted" "0" "$?"

        echo "$content" | grep -q "  - 'fd00:10:2::15'"
        _assert_eq "IPv6 SAN quoted" "0" "$?"
    )
}

# ============================================================
# Test: generate_kubeadm_config with config patch
# ============================================================
_case_generate_kubeadm_config_patch() {
    echo "=== Test: generate_kubeadm_config with config patch ==="
    (
        load_modules
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        _kubeadm_api_version() { echo "kubeadm.k8s.io/v1beta4"; }
        _kubeproxy_api_version() { echo "kubeproxy.config.k8s.io/v1alpha1"; }
        _kubelet_api_version() { echo "kubelet.config.k8s.io/v1beta1"; }
        get_cri_socket() { echo "unix:///run/containerd/containerd.sock"; }

        # shellcheck disable=SC2034 # used by generate_kubeadm_config
        KUBEADM_POD_CIDR=""
        # shellcheck disable=SC2034 # used by generate_kubeadm_config
        KUBEADM_SERVICE_CIDR=""
        # shellcheck disable=SC2034 # used by generate_kubeadm_config
        KUBEADM_API_ADDR=""
        # shellcheck disable=SC2034 # used by generate_kubeadm_config
        KUBEADM_CP_ENDPOINT=""
        # shellcheck disable=SC2034 # used by generate_kubeadm_config
        API_SERVER_EXTRA_SANS=""

        local tmpfile
        tmpfile=$(mktemp /tmp/test-patch-XXXXXX)
        echo "customKey: customValue" > "$tmpfile"
        # shellcheck disable=SC2034 # used by generate_kubeadm_config
        KUBEADM_CONFIG_PATCH="$tmpfile"

        local config_file
        config_file=$(generate_kubeadm_config)
        local content
        content=$(cat "$config_file")
        rm -f "$config_file" "$tmpfile"

        local has_patch="false"
        echo "$content" | grep -q "customKey: customValue" && has_patch="true"
        _assert_eq "config patch appended" "true" "$has_patch"
    )
}

@test "generate_kubeadm_config with extra SANs" {
    _case_generate_kubeadm_config_extra_sans
}

@test "generate_kubeadm_config quotes IPv6 literals" {
    _case_generate_kubeadm_config_ipv6_literals
}

@test "generate_kubeadm_config with config patch" {
    _case_generate_kubeadm_config_patch
}

# --- kubernetesVersion, imageRepository, patches ---

_fake_kubeadm_version() {
    cat > "$FAKE_BIN/kubeadm" <<'FAKE'
#!/bin/sh
case "$*" in
    "version -o short") echo v1.37.2 ;;
    *) exit 1 ;;
esac
FAKE
    chmod +x "$FAKE_BIN/kubeadm"
}

@test "kubeadm config pins the installed version and sets image repository and patches" {
    load_modules; quiet_logs
    _fake_kubeadm_version
    K8S_VERSION=1.37 PROXY_MODE=nftables CRI=containerd
    KUBEADM_IMAGE_REPOSITORY="mirror.example.com/k8s"
    KUBEADM_PATCHES_DIR="/etc/setup-k8s/patches"
    local cfg
    cfg=$(generate_kubeadm_config)
    grep -qx "kubernetesVersion: 'v1.37.2'" "$cfg"
    grep -qx "imageRepository: 'mirror.example.com/k8s'" "$cfg"
    grep -A1 -x 'patches:' "$cfg" | grep -qx "  directory: '/etc/setup-k8s/patches'"
    # patches belongs to InitConfiguration (before the ClusterConfiguration document)
    [ "$(grep -n -x 'patches:' "$cfg" | cut -d: -f1)" -lt "$(grep -n 'kind: ClusterConfiguration' "$cfg" | cut -d: -f1)" ]
    rm -f "$cfg"
}

@test "kubeadm config omits image repository and patches by default" {
    load_modules; quiet_logs
    _fake_kubeadm_version
    # shellcheck disable=SC2034 # read by generate_kubeadm_config
    K8S_VERSION=1.37 PROXY_MODE=iptables CRI=containerd
    local cfg
    cfg=$(generate_kubeadm_config)
    if grep -q -e '^imageRepository:' -e '^patches:' "$cfg"; then return 1; fi
    grep -qx "kubernetesVersion: 'v1.37.2'" "$cfg"
    rm -f "$cfg"
}

@test "parse_setup_args accepts patch versions, prerelease, image repository, and patches" {
    load_modules; quiet_logs
    local dir="$BATS_TEST_TMPDIR/patches"
    mkdir -p "$dir"
    parse_setup_args --kubernetes-version 1.37.2 --prerelease --image-repository mirror.example.com/k8s --patches "$dir"
    [ "$K8S_VERSION" = 1.37 ]
    [ "$K8S_PATCH_VERSION" = 1.37.2 ]
    [ "$K8S_PRERELEASE" = true ]
    [ "$KUBEADM_IMAGE_REPOSITORY" = mirror.example.com/k8s ]
    [ "$KUBEADM_PATCHES_DIR" = "$dir" ]
    run parse_setup_args --kubernetes-version 1.37.2.1
    [ "$status" -ne 0 ]
    run parse_setup_args --patches "$BATS_TEST_TMPDIR/missing"
    [ "$status" -ne 0 ]
}

@test "the requested patch version is installed and used for binaries" {
    load_modules; quiet_logs
    K8S_PATCH_VERSION=1.37.2
    [ "$(_resolve_k8s_patch_version 1.37)" = 1.37.2 ]
}

@test "prerelease uses the prerelease repository and version markers" {
    load_modules; quiet_logs
    CALLS="$BATS_TEST_TMPDIR/calls"
    pkg_repo_add() { echo "repo $*" >> "$CALLS"; }
    K8S_PRERELEASE=true
    DISTRO_PKG=apt
    _k8s_repo_add 1.38
    grep -q 'https://pkgs.k8s.io/core:/prerelease:/v1.38/' "$CALLS"
    fake_cmd curl 0 v1.38.0-beta.1
    [ "$(_resolve_k8s_patch_version 1.38)" = 1.38.0-beta.1 ]
    fake_calls | grep -q 'https://dl.k8s.io/release/latest-1.38.txt'
}

@test "--prerelease is rejected with distribution Kubernetes packages" {
    load_modules; quiet_logs
    # shellcheck disable=SC2034 # read by determine_k8s_version
    K8S_PRERELEASE=true DISTRO_K8S_SOURCE=distro K8S_VERSION=1.34
    run determine_k8s_version
    [ "$status" -ne 0 ]
}

@test "a config patch of a generated kind is merged, not added as a second document" {
    load_modules; quiet_logs
    _kubeadm_defaults() { :; }
    _kubeadm_api_version() { echo kubeadm.k8s.io/v1beta4; }
    _kubeproxy_api_version() { echo kubeproxy.config.k8s.io/v1alpha1; }
    _kubelet_api_version() { echo kubelet.config.k8s.io/v1beta1; }
    patch="$BATS_TEST_TMPDIR/patch.yaml"
    printf '%s\n' 'apiVersion: kubelet.config.k8s.io/v1beta1' 'kind: KubeletConfiguration' 'shutdownGracePeriod: 30s' \
        '---' 'apiVersion: kubeproxy.config.k8s.io/v1alpha1' 'kind: KubeProxyConfiguration' 'mode: iptables' > "$patch"
    SWAP_ENABLED=true PROXY_MODE=nftables KUBEADM_CONFIG_PATCH="$patch"
    config=$(generate_kubeadm_config)
    [ "$(grep -c '^kind: KubeletConfiguration' "$config")" -eq 1 ]
    [ "$(grep -c '^kind: KubeProxyConfiguration' "$config")" -eq 1 ]
    grep -qx 'failSwapOn: false' "$config"
    grep -qx 'shutdownGracePeriod: 30s' "$config"
    # The patch's fields win
    grep -qx 'mode: iptables' "$config"
    if grep -qx 'mode: nftables' "$config"; then return 1; fi
}

@test "cgroups v1 with Kubernetes 1.35+: kubelet gets failCgroupV1: false through the kubeadm patches" {
    load_modules; quiet_logs
    _has_cgroupv2() { return 1; }
    user_patches="$BATS_TEST_TMPDIR/user-patches"
    mkdir -p "$user_patches"
    echo 'shutdownGracePeriod: 30s' > "$user_patches/kubeletconfiguration+strategic.yaml"
    KUBEADM_PATCHES_DIR="$user_patches"
    kubeadm_prepare_node_patches 1.37
    [ "$KUBEADM_PATCHES_DIR" != "$user_patches" ]
    grep -qx 'failCgroupV1: false' "$KUBEADM_PATCHES_DIR"/kubeletconfiguration99setupk8scgroupv1+strategic.yaml
    # The user's patches are kept
    grep -qx 'shutdownGracePeriod: 30s' "$KUBEADM_PATCHES_DIR/kubeletconfiguration+strategic.yaml"
    [ "$(_kubeadm_patches_args)" = "--patches $KUBEADM_PATCHES_DIR" ]
}

@test "no kubelet patch on cgroups v2 or before Kubernetes 1.35" {
    load_modules; quiet_logs
    KUBEADM_PATCHES_DIR=""
    _has_cgroupv2() { return 0; }
    kubeadm_prepare_node_patches 1.37
    [ -z "$KUBEADM_PATCHES_DIR" ]
    _has_cgroupv2() { return 1; }
    kubeadm_prepare_node_patches 1.34
    [ -z "$KUBEADM_PATCHES_DIR" ]
}

@test "kubeadm skips SystemVerification on cgroups v1 nodes that allow it" {
    load_modules; quiet_logs
    _detect_init_system() { echo systemd; }
    KUBEADM_PATCHES_DIR=""
    [ -z "$(_kubeadm_preflight_ignore_args)" ]
    _has_cgroupv2() { return 1; }
    kubeadm_prepare_node_patches 1.37
    [ "$(_kubeadm_preflight_ignore_args)" = "--ignore-preflight-errors=SystemVerification" ]
}
