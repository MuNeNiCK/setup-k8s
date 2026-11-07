#!/usr/bin/env bats
# shellcheck disable=SC2034 # tests set globals read by the modules under test
# Component installs per package source. pkg_* and service helpers are
# replaced by recorders; assertions check what would be installed from where.

setup() {
    load '../helpers/common'
    load_modules
    quiet_logs
    CALLS="$BATS_TEST_TMPDIR/calls"
    : > "$CALLS"
    pkg_repo_add()          { echo "repo_add $*" >> "$CALLS"; }
    pkg_repo_remove()       { echo "repo_remove $*" >> "$CALLS"; }
    pkg_install()           { echo "install $*" >> "$CALLS"; }
    pkg_remove()            { echo "remove $*" >> "$CALLS"; }
    pkg_installed()         { return 1; }
    _finalize_containerd_setup() { echo "finalize containerd" >> "$CALLS"; }
    _finalize_crio_setup()  { echo "finalize crio" >> "$CALLS"; }
    _enable_and_start_kubelet() { echo "start kubelet" >> "$CALLS"; }
    _crio_prepare_config()  { :; }
    _detect_init_system()   { echo systemd; }
    rpm()                   { return 1; }
    fake_cmd kubeadm
    fake_cmd crio
    CRI=containerd
    K8S_VERSION=1.37
}

@test "kubernetes from pkgs.k8s.io (deb): per-minor repository, pinned and held" {
    DISTRO_PKG=apt DISTRO_K8S_SOURCE=pkgs
    k8s_install
    grep -qx 'repo_add kubernetes https://pkgs.k8s.io/core:/stable:/v1.37/deb/ https://pkgs.k8s.io/core:/stable:/v1.37/deb/Release.key' "$CALLS"
    grep -qx 'install --hold --repo kubernetes kubelet=1.37 kubeadm=1.37 kubectl=1.37 cri-tools' "$CALLS"
    grep -qx 'start kubelet' "$CALLS"
}

@test "kubernetes from pkgs.k8s.io (rpm): rpm repository key" {
    DISTRO_PKG=dnf DISTRO_K8S_SOURCE=pkgs
    k8s_install
    grep -qx 'repo_add kubernetes https://pkgs.k8s.io/core:/stable:/v1.37/rpm/ https://pkgs.k8s.io/core:/stable:/v1.37/rpm/repodata/repomd.xml.key' "$CALLS"
}

@test "kubernetes upgrade pins the exact patch version" {
    DISTRO_PKG=dnf DISTRO_K8S_SOURCE=pkgs
    k8s_upgrade_kubeadm 1.38.1
    k8s_upgrade_node 1.38.1
    grep -qx 'repo_add kubernetes https://pkgs.k8s.io/core:/stable:/v1.38/rpm/ https://pkgs.k8s.io/core:/stable:/v1.38/rpm/repodata/repomd.xml.key' "$CALLS"
    grep -qx 'install --hold --repo kubernetes kubeadm=1.38.1' "$CALLS"
    grep -qx 'install --hold --repo kubernetes kubelet=1.38.1 kubectl=1.38.1 cri-tools' "$CALLS"
}

@test "kubernetes from distribution packages pins only the core packages" {
    DISTRO_PKG=apk DISTRO_K8S_SOURCE=distro DISTRO_NAME=alpine
    DISTRO_K8S_PKGS="kubeadm kubelet kubectl kubelet-openrc cni-plugins cri-tools"
    pkg_available_version() { echo 1.37.1; }
    k8s_install
    grep -qx 'install --hold kubeadm=1.37 kubelet=1.37 kubectl=1.37 kubelet-openrc cni-plugins cri-tools' "$CALLS"
}

@test "kubernetes from distribution packages fails when the minor is not provided" {
    DISTRO_PKG=apk DISTRO_K8S_SOURCE=distro DISTRO_NAME=alpine
    DISTRO_K8S_PKGS="kubeadm kubelet kubectl"
    pkg_available_version() { echo 1.36.1; }
    run k8s_install
    [ "$status" -ne 0 ]
    if grep -q '^install' "$CALLS"; then return 1; fi
}

@test "default version follows the distribution packages" {
    DISTRO_PKG=pacman DISTRO_K8S_SOURCE=distro DISTRO_NAME=arch
    pkg_available_version() { echo 1.37.2; }
    _has_cgroupv2() { return 0; }
    K8S_VERSION=""
    determine_k8s_version
    [ "$K8S_VERSION" = "1.37" ]
}

@test "containerd from Docker (deb) uses the distribution path and codename" {
    DISTRO_PKG=apt DISTRO_CONTAINERD_SOURCE=docker DISTRO_DOCKER_REPO=ubuntu DISTRO_CODENAME=noble
    containerd_install
    grep -qx 'repo_add docker https://download.docker.com/linux/ubuntu https://download.docker.com/linux/ubuntu/gpg noble stable' "$CALLS"
    grep -qx 'install --no-weak-deps containerd.io' "$CALLS"
    grep -qx 'finalize containerd' "$CALLS"
}

@test "containerd from Docker (rpm) uses the rhel repository for RHEL clones" {
    DISTRO_PKG=dnf DISTRO_CONTAINERD_SOURCE=docker DISTRO_DOCKER_REPO=rhel
    containerd_install
    # shellcheck disable=SC2016 # literal dnf variables
    grep -qxF 'repo_add docker https://download.docker.com/linux/rhel/$releasever/$basearch/stable https://download.docker.com/linux/rhel/gpg' "$CALLS"
}

@test "containerd on RPM systems installs container-selinux first" {
    DISTRO_PKG=dnf DISTRO_CONTAINERD_SOURCE=docker DISTRO_DOCKER_REPO=rhel
    fake_cmd getenforce 0 Enforcing
    containerd_install
    [ "$(head -n 1 "$CALLS")" = "install container-selinux" ]
}

@test "containerd from OBS for openSUSE Leap" {
    DISTRO_PKG=zypper DISTRO_CONTAINERD_SOURCE=obs DISTRO_OBS_REPO="Virtualization:/containers/16.0"
    fake_cmd getenforce 1
    containerd_install
    grep -qx 'repo_add containers https://download.opensuse.org/repositories/Virtualization:/containers/16.0/ https://download.opensuse.org/repositories/Virtualization:/containers/16.0/repodata/repomd.xml.key' "$CALLS"
    grep -qx 'install --repo containers containerd' "$CALLS"
}

@test "containerd from distribution packages" {
    DISTRO_PKG=apk DISTRO_CONTAINERD_SOURCE=distro DISTRO_CONTAINERD_PKGS="containerd containerd-openrc"
    containerd_install
    grep -qx 'install containerd containerd-openrc' "$CALLS"
}

@test "CRI-O from isv:cri-o matches the Kubernetes minor" {
    DISTRO_PKG=dnf DISTRO_CRIO_SOURCE=isv CRI=crio
    fake_cmd getenforce 1
    crio_install
    grep -qx 'repo_add cri-o https://download.opensuse.org/repositories/isv:/cri-o:/stable:/v1.37/rpm/ https://download.opensuse.org/repositories/isv:/cri-o:/stable:/v1.37/rpm/repodata/repomd.xml.key' "$CALLS"
    grep -qx 'install --repo cri-o cri-o' "$CALLS"
    grep -qx 'finalize crio' "$CALLS"
}

@test "CRI-O from distribution packages" {
    DISTRO_PKG=pacman DISTRO_CRIO_SOURCE=distro DISTRO_CRIO_PKGS="iptables-nft cri-o" CRI=crio
    crio_install
    grep -qx 'install iptables-nft cri-o' "$CALLS"
}

@test "kubelet node-ip goes to the environment file read by the unit" {
    KUBELET_NODE_IP=10.0.0.5
    _kubelet_env_file() { echo "$BATS_TEST_TMPDIR/sysconfig/kubelet"; }
    _configure_kubelet_node_ip
    grep -qx 'KUBELET_EXTRA_ARGS="--node-ip=10.0.0.5"' "$BATS_TEST_TMPDIR/sysconfig/kubelet"
}

@test "prerelease installs Kubernetes packages without cri-tools and adds crictl" {
    DISTRO_PKG=apt DISTRO_K8S_SOURCE=pkgs K8S_VERSION=1.38 K8S_PRERELEASE=true
    _k8s_remove_conflicting_packages() { :; }
    _k8s_repo_add() { echo "repo $1" >> "$CALLS"; }
    pkg_install() { echo "install $*" >> "$CALLS"; }
    _crictl_install_binary() { echo "crictl $1" >> "$CALLS"; }
    _enable_and_start_kubelet() { :; }
    fake_cmd kubeadm
    k8s_install
    grep -qx 'install --hold --repo kubernetes kubelet=1.38 kubeadm=1.38 kubectl=1.38' "$CALLS"
    grep -qx 'crictl 1.38' "$CALLS"
}

@test "crictl comes from the cri-tools release of the minor or the previous minor" {
    _detect_arch() { echo amd64; }
    cat > "$FAKE_BIN/curl" <<FAKE
#!/bin/sh
echo "curl \$*" >> "$FAKE_LOG"
case "\$*" in
    *v1.38.0*) exit 22 ;;
esac
exit 0
FAKE
    chmod +x "$FAKE_BIN/curl"
    _download_with_checksum() { echo "download $1 $3" >> "$CALLS"; : > "$2"; }
    tar() { echo "tar $*" >> "$CALLS"; }
    _crictl_install_binary 1.38 2>/dev/null || true
    grep -qx 'download https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.37.0/crictl-v1.37.0-linux-amd64.tar.gz https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.37.0/crictl-v1.37.0-linux-amd64.tar.gz.sha256' "$CALLS"
}

@test "cleanup removes the distribution packages of the install (cni-plugins kept with --preserve-cni)" {
    DISTRO_PKG=pacman DISTRO_K8S_SOURCE=distro
    DISTRO_K8S_PKGS="kubeadm kubelet kubectl crictl cni-plugins"
    pkg_remove() { echo "remove $*" >> "$CALLS"; }
    _k8s_remove_binaries() { :; }
    k8s_remove
    grep -qx 'remove kubeadm kubelet kubectl crictl cni-plugins kubelet-openrc' "$CALLS"
    : > "$CALLS"
    PRESERVE_CNI=true k8s_remove
    grep -qx 'remove kubeadm kubelet kubectl crictl kubelet-openrc' "$CALLS"
}

@test "cleanup keeps the containerd service files of distribution packages" {
    pkg_repo_remove() { :; }
    _CONTAINERD_BIN_DIR="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$_CONTAINERD_BIN_DIR"
    _CONTAINERD_SERVICE_FILES="$BATS_TEST_TMPDIR/init.d-containerd"
    touch "$_CONTAINERD_SERVICE_FILES"
    containerd_cleanup
    [ -e "$_CONTAINERD_SERVICE_FILES" ]
    # A binary install's service file is removed with the binaries
    touch "$_CONTAINERD_BIN_DIR/containerd"
    containerd_cleanup
    [ ! -e "$_CONTAINERD_SERVICE_FILES" ] && [ ! -e "$_CONTAINERD_BIN_DIR/containerd" ]
}

@test "upgrade moves CRI-O from the isv repository to the new minor and checks it" {
    DISTRO_PKG=apt DISTRO_CRIO_SOURCE=isv
    VERSION_FILE="$BATS_TEST_TMPDIR/crio-version"
    echo 1.36.6 > "$VERSION_FILE"
    cat > "$FAKE_BIN/crio" <<FAKE
#!/bin/sh
echo "crio version \$(cat "$VERSION_FILE")"
FAKE
    chmod +x "$FAKE_BIN/crio"
    pkg_repo_add() { echo "repo_add $*" >> "$CALLS"; }
    pkg_install() { echo "install $*" >> "$CALLS"; echo "${NEW_VERSION:-1.37.3}" > "$VERSION_FILE"; }
    _crio_prepare_config() { :; }
    _start_crio_with_diagnostics() { echo restart >> "$CALLS"; }
    crio_set_minor 1.37
    grep -q '^repo_add cri-o https://download.opensuse.org/repositories/isv:/cri-o:/stable:/v1.37/deb/ ' "$CALLS"
    grep -qx 'install --repo cri-o cri-o=1.37' "$CALLS"
    grep -qx restart "$CALLS"
    # Already at the minor: nothing to do
    : > "$CALLS"
    crio_set_minor 1.37
    [ ! -s "$CALLS" ]
    # The package manager kept the old version: fails
    echo 1.36.6 > "$VERSION_FILE"
    NEW_VERSION=1.36.6
    run crio_set_minor 1.37
    [ "$status" -ne 0 ]
}

@test "CRI-O from distribution packages is left to the distribution on upgrade" {
    DISTRO_CRIO_SOURCE=distro
    fake_cmd crio 0 "crio version 1.35.1"
    pkg_install() { echo "install $*" >> "$CALLS"; }
    crio_set_minor 1.36
    [ ! -s "$CALLS" ]
}

@test "SELinux: CRI-O gets a module that lets systemd attach its device filters" {
    STATE="$BATS_TEST_TMPDIR/modules"; : > "$STATE"
    cat > "$FAKE_BIN/semodule" <<FAKE
#!/bin/sh
echo "semodule \$*" >> "$FAKE_LOG"
case "\$1" in
    -l) cat "$STATE" ;;
    -i) cat "\$2" > "$BATS_TEST_TMPDIR/module.cil"; basename "\$2" .cil >> "$STATE" ;;
    -r) : > "$STATE" ;;
esac
FAKE
    chmod +x "$FAKE_BIN/semodule"
    fake_cmd getenforce 0 Enforcing
    _crio_selinux_module_install
    grep -qxF '(allow init_t container_runtime_t (bpf (prog_run)))' "$BATS_TEST_TMPDIR/module.cil"
    _crio_selinux_module_loaded
    # Installed once
    : > "$FAKE_LOG"
    _crio_selinux_module_install
    if fake_calls | grep -q 'semodule -i'; then return 1; fi
    # Removed with CRI-O
    DISTRO_PKG=""
    crio_remove
    run _crio_selinux_module_loaded
    [ "$status" -ne 0 ]
}

@test "SELinux disabled or absent: no module" {
    fake_cmd getenforce 0 Disabled
    fake_cmd semodule
    _crio_selinux_module_install
    if fake_calls | grep -q 'semodule -i'; then return 1; fi
}

@test "CRI-O uses runc on cgroups v1 (crun cannot set device permissions there)" {
    _CRIO_CONF_DIR="$BATS_TEST_TMPDIR/crio.conf.d"
    k8s_pause_image() { echo registry.k8s.io/pause:3.10.2; }
    fake_cmd runc
    _has_cgroupv2() { return 1; }
    _write_crio_config 02-kubernetes.conf systemd
    f="$_CRIO_CONF_DIR/99-setup-k8s-cgroupv1.conf"
    grep -qx 'default_runtime = "runc"' "$f"
    if grep -q 'runtimes.runc' "$f"; then return 1; fi
    # Sorts after the packages' drop-ins (10-crio.conf)
    [ "$(printf '%s\n' 10-crio.conf 99-setup-k8s-cgroupv1.conf 02-kubernetes.conf | sort | tail -n 1)" = 99-setup-k8s-cgroupv1.conf ]
    _has_cgroupv2() { return 0; }
    _write_crio_config 02-kubernetes.conf systemd
    [ ! -e "$f" ]
}
