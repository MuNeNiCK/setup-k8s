#!/usr/bin/env bats
# shellcheck disable=SC2034 # tests set globals read by the modules under test
# Package manager adapters, tested through the pkg_* interface with fake
# package manager commands on PATH.

setup() {
    load '../helpers/common'
    load_modules
    quiet_logs
    _APT_SOURCES_DIR="$BATS_TEST_TMPDIR/sources.list.d"
    _APT_KEYRING_DIR="$BATS_TEST_TMPDIR/keyrings"
    _DNF_REPOS_DIR="$BATS_TEST_TMPDIR/yum.repos.d"
}

# --- apt ---

@test "apt: versioned install resolves the exact patch and holds the packages" {
    DISTRO_PKG=apt
    fake_cmd apt-cache 0 " kubeadm | 1.37.3-1.1 | https://pkgs.k8s.io/core:/stable:/v1.37/deb  Packages
 kubeadm | 1.37.2-1.1 | https://pkgs.k8s.io/core:/stable:/v1.37/deb  Packages"
    fake_cmd apt-get
    fake_cmd apt-mark
    pkg_install --hold --repo kubernetes kubeadm=1.37.2 cri-tools
    fake_calls | grep -qx 'apt-get install -y --allow-change-held-packages --allow-downgrades kubeadm=1.37.2-1.1 cri-tools'
    fake_calls | grep -qx 'apt-mark hold kubeadm cri-tools'
}

@test "apt: a minor version selects the newest patch of that minor" {
    DISTRO_PKG=apt
    fake_cmd apt-cache 0 " kubelet | 1.37.3-1.1 | repo
 kubelet | 1.37.2-1.1 | repo"
    fake_cmd apt-get
    pkg_install kubelet=1.37
    fake_calls | grep -q 'apt-get install .* kubelet=1.37.3-1.1$'
}

@test "apt: an unavailable version fails without installing" {
    DISTRO_PKG=apt
    fake_cmd apt-cache 0 " kubeadm | 1.37.3-1.1 | repo"
    fake_cmd apt-get
    run pkg_install kubeadm=1.37.9
    [ "$status" -ne 0 ]
    if fake_calls | grep -q '^apt-get install'; then return 1; fi
}

@test "apt: repo_add writes a signed source entry" {
    DISTRO_PKG=apt
    fake_cmd dpkg 0 "amd64"
    fake_cmd apt-get
    # gpg writes the keyring given with -o
    cat > "$FAKE_BIN/gpg" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do [ "$1" = "-o" ] && : > "$2"; shift; done
EOF
    chmod +x "$FAKE_BIN/gpg"
    # curl writes the key file given with -o
    cat > "$FAKE_BIN/curl" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do [ "$1" = "-o" ] && echo KEY > "$2"; shift; done
EOF
    chmod +x "$FAKE_BIN/curl"
    pkg_repo_add docker https://download.docker.com/linux/ubuntu https://download.docker.com/linux/ubuntu/gpg noble stable
    grep -qx "deb \[arch=amd64 signed-by=$_APT_KEYRING_DIR/docker.gpg\] https://download.docker.com/linux/ubuntu noble stable" "$_APT_SOURCES_DIR/docker.list"
    pkg_repo_add kubernetes https://pkgs.k8s.io/core:/stable:/v1.37/deb/ https://pkgs.k8s.io/core:/stable:/v1.37/deb/Release.key
    grep -qx "deb \[signed-by=$_APT_KEYRING_DIR/kubernetes.gpg\] https://pkgs.k8s.io/core:/stable:/v1.37/deb/ /" "$_APT_SOURCES_DIR/kubernetes.list"
}

@test "apt: remove purges only installed packages" {
    DISTRO_PKG=apt
    cat > "$FAKE_BIN/dpkg-query" <<'EOF'
#!/bin/sh
for a in "$@"; do last="$a"; done
[ "$last" = kubeadm ] && echo "install ok installed"
exit 0
EOF
    chmod +x "$FAKE_BIN/dpkg-query"
    fake_cmd apt-get
    fake_cmd apt-mark
    pkg_remove kubeadm cri-o
    fake_calls | grep -qx 'apt-get purge -y kubeadm'
}

@test "apt: held packages count as installed and are unheld before purge" {
    DISTRO_PKG=apt
    cat > "$FAKE_BIN/dpkg-query" <<'EOF'
#!/bin/sh
for a in "$@"; do last="$a"; done
case "$last" in
    kubelet) echo "hold ok installed" ;;
    kubeadm) echo "install ok installed" ;;
    *) echo "unknown ok not-installed" ;;
esac
EOF
    chmod +x "$FAKE_BIN/dpkg-query"
    fake_cmd apt-get
    fake_cmd apt-mark
    pkg_installed kubelet
    pkg_remove kubeadm kubelet cri-o
    fake_calls | grep -qx 'apt-mark unhold kubeadm kubelet'
    fake_calls | grep -qx 'apt-get purge -y kubeadm kubelet'
}

# --- dnf ---

@test "dnf4: pinned install lifts the repository exclude and records the hold" {
    DISTRO_PKG=dnf
    fake_cmd dnf 0 "4.20.0"
    fake_cmd curl
    pkg_repo_add kubernetes https://pkgs.k8s.io/core:/stable:/v1.37/rpm/ https://pkgs.k8s.io/core:/stable:/v1.37/rpm/repodata/repomd.xml.key
    : > "$FAKE_LOG"
    pkg_install --hold --repo kubernetes kubeadm=1.37.2 kubelet=1.37 cri-tools
    fake_calls | grep -qx 'dnf install -y --disableexcludes=kubernetes kubeadm-1.37.2-\* kubelet cri-tools'
    grep -qx 'exclude=kubeadm kubelet cri-tools' "$_DNF_REPOS_DIR/kubernetes.repo"
}

@test "dnf5: pinned install uses the dnf5 option syntax" {
    DISTRO_PKG=dnf
    fake_cmd dnf 0 "dnf5 version 5.2.13.1"
    pkg_repo_add kubernetes https://example.invalid/rpm/ https://example.invalid/key
    : > "$FAKE_LOG"
    pkg_install --repo kubernetes kubeadm=1.37.2
    fake_calls | grep -qx 'dnf install -y --setopt=disable_excludes=kubernetes kubeadm-1.37.2-\*'
}

@test "pacman: a package that only provides a name is not that package" {
    DISTRO_PKG=pacman
    fake_cmd pacman 0 'kubeadm-git
containerd'
    pkg_installed kubeadm-git
    pkg_installed containerd
    run ! pkg_installed kubeadm
}

@test "dnf: repo_add writes the baseurl unexpanded" {
    DISTRO_PKG=dnf
    fake_cmd dnf
    # shellcheck disable=SC2016 # literal dnf variables
    pkg_repo_add docker 'https://download.docker.com/linux/rhel/$releasever/$basearch/stable' https://download.docker.com/linux/rhel/gpg
    # shellcheck disable=SC2016
    grep -qxF 'baseurl=https://download.docker.com/linux/rhel/$releasever/$basearch/stable' "$_DNF_REPOS_DIR/docker.repo"
    grep -qx 'gpgcheck=1' "$_DNF_REPOS_DIR/docker.repo"
}

@test "dnf: --no-weak-deps disables weak dependencies" {
    DISTRO_PKG=dnf
    fake_cmd dnf 0 "4.20.0"
    pkg_install --no-weak-deps containerd.io
    fake_calls | grep -qx 'dnf install -y --setopt=install_weak_deps=False containerd.io'
}

# --- zypper ---

@test "zypper: pinned install allows downgrades and locks the packages" {
    DISTRO_PKG=zypper
    fake_cmd zypper
    pkg_install --hold kubeadm=1.37.2 cri-tools
    fake_calls | grep -qx 'zypper --non-interactive install -y --allow-vendor-change --replacefiles --oldpackage kubeadm=1.37.2 cri-tools'
    fake_calls | grep -qx 'zypper --non-interactive addlock kubeadm cri-tools'
}

# --- apk ---

@test "apk: versions become fuzzy constraints" {
    DISTRO_PKG=apk
    fake_cmd apk
    pkg_install --hold kubeadm=1.36 kubelet-openrc
    fake_calls | grep -qx 'apk add --no-cache kubeadm=~1.36 kubelet-openrc'
}

@test "apk: available_version strips the package release" {
    DISTRO_PKG=apk
    fake_cmd apk 0 "kubeadm policy:
  1.36.1-r2:
    https://dl-cdn.alpinelinux.org/alpine/v3.24/community"
    run pkg_available_version kubeadm
    [ "$output" = "1.36.1" ]
}

# --- pacman ---

@test "pacman: satisfied targets are skipped and conflicts are accepted" {
    DISTRO_PKG=pacman
    cat > "$FAKE_BIN/pacman" <<EOF
#!/bin/sh
echo "pacman \$*" >> "$FAKE_LOG"
# -T prints unsatisfied dependencies; iptables is provided by iptables-nft
[ "\$1" = "-T" ] && [ "\$2" != iptables ] && echo "\$2"
exit 0
EOF
    chmod +x "$FAKE_BIN/pacman"
    pkg_install iptables cri-o
    fake_calls | grep -qx 'pacman -S --noconfirm --needed --ask 4 cri-o'
}

# --- interface ---

@test "pkg_format maps adapters to package formats" {
    local pm expected
    for pm in apt:deb dnf:rpm zypper:rpm apk:apk pacman:pacman; do
        DISTRO_PKG="${pm%%:*}"
        expected="${pm#*:}"
        [ "$(pkg_format)" = "$expected" ]
    done
}

@test "pkg_* fails clearly without a package manager" {
    DISTRO_PKG=""
    run pkg_install curl
    [ "$status" -ne 0 ]
}

@test "pkg_refresh retries a transient failure and fails after three attempts" {
    DISTRO_PKG=dnf
    sleep() { :; }
    TRIES="$BATS_TEST_TMPDIR/tries"; : > "$TRIES"
    _pkg_dnf_refresh() { echo x >> "$TRIES"; [ "$(wc -l < "$TRIES")" -ge "${OK_AT:-99}" ]; }
    OK_AT=2 pkg_refresh
    : > "$TRIES"
    run pkg_refresh
    [ "$status" -ne 0 ]
    [ "$(wc -l < "$TRIES")" -eq 3 ]
}

@test "dnf and zypper: a minor version installs its newest patch, also when older than installed" {
    DISTRO_PKG=dnf
    cat > "$FAKE_BIN/dnf" <<'FAKE'
#!/bin/sh
echo "dnf $*" >> "$FAKE_LOG"
case "$*" in
    --version) echo 4.20.0 ;;
    *"list --showduplicates"*) printf '%s\n' 'Installed Packages' 'cri-o.x86_64  1.37.3-150500.1.1  @cri-o' 'Available Packages' \
        'cri-o.x86_64  1.36.2-150500.1.1  cri-o' 'cri-o.x86_64  1.36.10-150500.1.1  cri-o' ;;
esac
exit 0
FAKE
    chmod +x "$FAKE_BIN/dnf"
    fake_cmd rpm 0 "1.37.3"
    pkg_install cri-o=1.36
    fake_calls | grep -qx 'dnf install -y cri-o-1.36.10-\*'
    fake_calls | grep -qx 'dnf downgrade -y cri-o-1.36.10'

    DISTRO_PKG=zypper
    : > "$FAKE_LOG"
    fake_cmd zypper 0 'S  | Name  | Type    | Version            | Arch   | Repository
---+-------+---------+--------------------+--------+-----------
i+ | cri-o | package | 1.36.6-150500.1.1  | x86_64 | cri-o
v  | cri-o | package | 1.37.2-150500.1.1  | x86_64 | cri-o'
    pkg_install cri-o=1.37
    fake_calls | grep -q 'zypper --non-interactive install -y --allow-vendor-change --replacefiles --oldpackage cri-o=1.37.2$'
}
