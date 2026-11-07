#!/usr/bin/env bats
# shellcheck disable=SC2034 # tests set globals read by the modules under test
# Kubernetes version knowledge (lib/core/k8s_version.sh).

setup() {
    load '../helpers/common'
    load_modules
    quiet_logs
}

@test "k8s_version_ge compares major and minor numerically" {
    k8s_version_ge 1.37 1.35
    k8s_version_ge 1.35 1.35
    k8s_version_ge 1.35.10 1.35
    k8s_version_ge v1.40.1 1.9
    k8s_version_ge 2.0 1.99
    run ! k8s_version_ge 1.34 1.35
    run ! k8s_version_ge 1.9 1.10
    run ! k8s_version_ge "" 1.28
}

@test "k8s_supports uses the feature table" {
    K8S_VERSION=1.30
    k8s_supports swap
    run ! k8s_supports swap 1.29
    run ! k8s_supports nftables 1.28
    K8S_VERSION=1.37
    k8s_supports nftables
    k8s_supports nftables-ga
    k8s_supports ipvs-deprecated
    k8s_supports selinux-mount
    run ! k8s_supports containerd-v2-required
    k8s_supports containerd-v2-required 1.38
    k8s_supports cgroupv2-required 1.35
    run ! k8s_supports cgroupv2-required 1.34
}

@test "k8s_supports rejects unknown features" {
    run k8s_supports no-such-feature 1.37
    [ "$status" -ne 0 ]
}

@test "k8s_pause_image follows the installed kubeadm" {
    cat > "$FAKE_BIN/kubeadm" <<'EOF'
#!/bin/sh
case "$*" in
    "version -o short") echo v1.37.2 ;;
    "config images list --kubernetes-version v1.37.2")
        printf '%s\n' registry.k8s.io/kube-apiserver:v1.37.2 registry.k8s.io/pause:3.10.2 registry.k8s.io/etcd:3.7.0-0 ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$FAKE_BIN/kubeadm"
    PAUSE_IMAGE_VERSION=""
    [ "$(k8s_pause_image)" = "registry.k8s.io/pause:3.10.2" ]
}

@test "PAUSE_IMAGE_VERSION overrides the pause image" {
    PAUSE_IMAGE_VERSION=3.9
    [ "$(k8s_pause_image)" = "registry.k8s.io/pause:3.9" ]
}

@test "k8s_pause_image falls back when kubeadm cannot report it" {
    fake_cmd kubeadm 1
    PAUSE_IMAGE_VERSION=""
    [ "$(k8s_pause_image)" = "registry.k8s.io/pause:${_K8S_PAUSE_FALLBACK}" ]
}

@test "determine_k8s_version warns about cgroups v1 from the cgroupv2-required minimum" {
    _has_cgroupv2() { return 1; }
    log_warn() { echo "WARN: $*"; }
    fake_cmd curl 0 v1.37.2
    K8S_VERSION=1.35
    run determine_k8s_version
    [ "$status" -eq 0 ]
    [[ "$output" == *"failCgroupV1: false"* ]]
    K8S_VERSION=1.34
    run determine_k8s_version
    [ "$status" -eq 0 ]
    [[ "$output" != *"cgroups v1"* ]]
}

@test "nftables proxy mode is rejected below the feature minimum" {
    PROXY_MODE=nftables K8S_VERSION=1.28
    run validate_proxy_mode
    [ "$status" -ne 0 ]
    PROXY_MODE=nftables K8S_VERSION=1.37
    validate_proxy_mode
}

@test "kubeadm config falls back to v1beta4 when the API version is unknown" {
    _kubeadm_defaults() { :; }
    [ "$(_kubeadm_api_version)" = "kubeadm.k8s.io/v1beta4" ]
}
