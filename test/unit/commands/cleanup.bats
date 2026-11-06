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
