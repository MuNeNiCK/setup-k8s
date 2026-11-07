#!/usr/bin/env bats
# shellcheck disable=SC2034 # tests set globals read by the modules under test
# cleanup verification (_cleanup_leftovers): independent checks of what
# setup-k8s installs or configures.

setup() {
    load '../helpers/common'
    load_modules
    quiet_logs
    _CLEANUP_ETC="$BATS_TEST_TMPDIR/etc"
    mkdir -p "$_CLEANUP_ETC"
    # Nothing on PATH or in the package database by default
    command() { if [ "$1" = -v ]; then case "$2" in kubeadm|kubelet|kubectl|crio|apt-mark|dnf|zypper) return 1 ;; esac; fi; builtin command "$@"; }
    pkg_installed() { case " ${INSTALLED:-} " in *" $1 "*) return 0 ;; esac; return 1; }
    DISTRO_PKG=apt
    # No Kubernetes processes unless a test says so
    fake_cmd pgrep 1
}

@test "a clean node has no leftovers" {
    [ -z "$(_cleanup_leftovers)" ]
}

@test "a package left installed is reported even if its removal step succeeded" {
    INSTALLED="kubelet"
    [ "$(_cleanup_leftovers)" = "package kubelet" ]
}

@test "binaries, holds, repositories, keys, and kubelet configuration are reported" {
    command() { if [ "$1" = -v ]; then case "$2" in kubelet) echo /usr/bin/kubelet; return 0 ;; apt-mark) return 0 ;; kubeadm|kubectl|crio|dnf|zypper) return 1 ;; esac; fi; builtin command "$@"; }
    fake_cmd apt-mark 0 "kubeadm"
    mkdir -p "$_CLEANUP_ETC/apt/keyrings" "$_CLEANUP_ETC/kubernetes" "$_CLEANUP_ETC/yum.repos.d"
    touch "$_CLEANUP_ETC/apt/keyrings/kubernetes-apt-keyring.gpg" "$_CLEANUP_ETC/yum.repos.d/docker-ce.repo"
    left=$(_cleanup_leftovers)
    [[ "$left" == *"binary /usr/bin/kubelet"* ]]
    [[ "$left" == *"hold kubeadm"* ]]
    [[ "$left" == *"apt/keyrings/kubernetes-apt-keyring.gpg"* ]]
    [[ "$left" == *"yum.repos.d/docker-ce.repo"* ]]
    [[ "$left" == *"directory $_CLEANUP_ETC/kubernetes"* ]]
}

@test "cleanup_installed_components fails when something is left" {
    k8s_remove() { :; }
    crio_remove() { :; }
    containerd_cleanup() { :; }
    system_cleanup() { :; }
    _service_reload() { :; }
    PRESERVE_CNI=false
    cleanup_installed_components
    INSTALLED="kubeadm"
    run cleanup_installed_components
    [ "$status" -ne 0 ]
}

@test "a Kubernetes process still running is reported" {
    cat > "$FAKE_BIN/pgrep" <<'FAKE'
#!/bin/sh
[ "$2" = kube-vip ]
FAKE
    chmod +x "$FAKE_BIN/pgrep"
    [ "$(_cleanup_leftovers)" = "process kube-vip" ]
}

@test "the VIP is released after kubeadm reset has removed kube-vip" {
    CALLS="$BATS_TEST_TMPDIR/calls"
    _CLEANUP_KUBE_VIP_MANIFEST="$BATS_TEST_TMPDIR/kube-vip.yaml"
    _generate_kube_vip_manifest 10.0.0.100 eth0 img /etc/kubernetes/admin.conf > "$_CLEANUP_KUBE_VIP_MANIFEST"
    command() { if [ "$1" = -v ] && [ "$2" = kubeadm ]; then return 0; fi; builtin command "$@"; }
    kubeadm() { echo "kubeadm $*" >> "$CALLS"; rm -f "$_CLEANUP_KUBE_VIP_MANIFEST"; }
    kube_vip_release() { echo "release $(grep -A1 'name: address' "$1" | tail -n 1 | tr -d ' ')" >> "$CALLS"; }
    reset_kubernetes_cluster
    [ "$(cat "$CALLS")" = 'kubeadm reset -f
release value:"10.0.0.100"' ]
}

@test "kubeadm reset runs while the container runtime still runs" {
    ORDER="$BATS_TEST_TMPDIR/order"
    for fn in stop_kubernetes_services stop_cri_services reset_kubernetes_cluster remove_kubernetes_configs \
              restore_fstab_swap restore_zram_swap cleanup_cni_conditionally cleanup_network_configs cleanup_kube_configs \
              cleanup_crictl_config reset_iptables reset_containerd_config _service_reload cleanup_installed_components \
              cleanup_kubernetes_completions _require_root parse_cleanup_args _ensure_distro_detected confirm_cleanup \
              check_docker_warning _audit_start _audit_done; do
        eval "$fn() { echo $fn >> \"\$ORDER\"; }"
    done
    DRY_RUN=false
    run _run_cleanup
    [ "$status" -eq 0 ]
    [ "$(grep -n -x reset_kubernetes_cluster "$ORDER" | cut -d: -f1)" -lt "$(grep -n -x stop_cri_services "$ORDER" | cut -d: -f1)" ]
    [ "$(grep -n -x stop_kubernetes_services "$ORDER" | cut -d: -f1)" -lt "$(grep -n -x reset_kubernetes_cluster "$ORDER" | cut -d: -f1)" ]
}
