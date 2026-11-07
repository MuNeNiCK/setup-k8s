#!/bin/sh

# Kubernetes node components (kubeadm, kubelet, kubectl).
#
# Source is DISTRO_K8S_SOURCE:
#   pkgs    pkgs.k8s.io repository for the Kubernetes minor version (deb/rpm)
#   distro  distribution packages (DISTRO_K8S_PKGS)
#   binary  release binaries from dl.k8s.io with a kubelet service definition
#
#   k8s_install                     Install for K8S_VERSION (MAJOR.MINOR)
#   k8s_upgrade_kubeadm <version>   Upgrade kubeadm to MAJOR.MINOR.PATCH
#   k8s_upgrade_node <version>      Upgrade kubelet and kubectl to MAJOR.MINOR.PATCH
#   k8s_remove                      Remove packages, repository, and binaries

_K8S_CORE_PKGS="kubeadm kubelet kubectl"

# --- pkgs.k8s.io ---

_k8s_repo_add() {
    local minor="$1" channel=stable base
    [ "${K8S_PRERELEASE:-false}" = true ] && channel=prerelease
    base="https://pkgs.k8s.io/core:/${channel}:/v${minor}"
    case "$(pkg_format)" in
        deb) pkg_repo_add kubernetes "${base}/deb/" "${base}/deb/Release.key" ;;
        rpm) pkg_repo_add kubernetes "${base}/rpm/" "${base}/rpm/repodata/repomd.xml.key" ;;
        *)   log_error "pkgs.k8s.io provides deb and rpm packages only"; return 1 ;;
    esac
}

# Remove Kubernetes packages shipped by the distribution (e.g. kubernetes1.31-*)
# that conflict with pkgs.k8s.io packages.
_k8s_remove_conflicting_packages() {
    [ "$(pkg_format)" = rpm ] || return 0
    local conflicting
    conflicting=$(rpm -qa --qf '%{NAME}\n' 'kubernetes1*' 2>/dev/null | tr '\n' ' ')
    if [ -n "$conflicting" ]; then
        log_info "Removing distribution Kubernetes packages to avoid conflicts: $conflicting"
        # shellcheck disable=SC2086 # space-separated package names
        pkg_remove $conflicting || return 1
    fi
}

# --- distribution packages ---

# Print package specs for the distro source, pinning the core packages.
_k8s_distro_specs() {
    local version="$1" pkg specs=""
    for pkg in $DISTRO_K8S_PKGS; do
        case " $_K8S_CORE_PKGS " in
            *" $pkg "*) specs="${specs}${specs:+ }${pkg}=${version}" ;;
            *)          specs="${specs}${specs:+ }${pkg}" ;;
        esac
    done
    echo "$specs"
}

# Fail with a clear message when the distribution does not provide the
# requested Kubernetes minor version.
_k8s_require_distro_version() {
    local wanted="$1" available
    available=$(pkg_available_version kubeadm)
    if [ -z "$available" ]; then
        log_error "kubeadm is not available from ${DISTRO_NAME} packages"
        return 1
    fi
    if [ "$(_k8s_minor_version "$available")" != "$(_k8s_minor_version "$wanted")" ]; then
        log_error "Kubernetes ${wanted} is not available from ${DISTRO_NAME} packages (available: ${available})"
        log_error "  Use --kubernetes-version $(_k8s_minor_version "$available"), or --distro generic to install release binaries"
        return 1
    fi
}

# Print the Kubernetes minor version provided by distribution packages.
k8s_distro_minor_version() {
    local available
    available=$(pkg_available_version kubeadm)
    [ -n "$available" ] && _k8s_minor_version "$available"
}

# --- release binaries ---

# Resolve the release version to install from MAJOR.MINOR: the requested
# patch version, or the latest stable (prerelease: latest) of that minor.
_resolve_k8s_patch_version() {
    local minor="$1" marker=stable
    if [ -n "${K8S_PATCH_VERSION:-}" ] && [ "$(_k8s_minor_version "$K8S_PATCH_VERSION")" = "$minor" ]; then
        echo "$K8S_PATCH_VERSION"
        return 0
    fi
    [ "${K8S_PRERELEASE:-false}" = true ] && marker=latest
    curl -fsSL --retry 3 --retry-delay 2 "https://dl.k8s.io/release/${marker}-${minor}.txt" | tr -d 'v'
}

# Download and install a single K8s binary with checksum verification
# Install crictl from the cri-tools release of the Kubernetes minor (or the
# previous minor, as cri-tools releases after Kubernetes prereleases).
# Usage: _crictl_install_binary <k8s_minor>
_crictl_install_binary() {
    local minor="$1" arch major m version file url tmp
    arch=$(_detect_arch)
    major="${minor%%.*}"
    m="${minor#*.}"
    for version in "v${major}.${m}.0" "v${major}.$((m - 1)).0"; do
        file="crictl-${version}-linux-${arch}.tar.gz"
        url="https://github.com/kubernetes-sigs/cri-tools/releases/download/${version}/${file}"
        curl -fsSL -o /dev/null -I "$url" 2>/dev/null || continue
        tmp=$(mktemp /tmp/crictl-XXXXXX)
        if ! _download_with_checksum "$url" "$tmp" "${url}.sha256"; then
            rm -f "$tmp"
            return 1
        fi
        tar -xzf "$tmp" -C /usr/local/bin crictl || { rm -f "$tmp"; return 1; }
        rm -f "$tmp"
        chmod 0755 /usr/local/bin/crictl
        log_info "crictl ${version} installed to /usr/local/bin/crictl"
        return 0
    done
    log_error "No cri-tools release found for Kubernetes ${minor}"
    return 1
}

_install_k8s_binary() {
    local binary="$1" version="$2"
    local arch
    arch=$(_detect_arch)
    local url="https://dl.k8s.io/release/v${version}/bin/linux/${arch}/${binary}"
    _download_with_checksum "$url" "/usr/local/bin/${binary}" "${url}.sha256"
}

# Install kubelet service file (systemd unit or OpenRC init script)
_install_kubelet_service() {
    case "$(_detect_init_system)" in
        systemd)
            cat > /etc/systemd/system/kubelet.service <<'UNIT'
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/local/bin/kubelet
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
            mkdir -p /etc/systemd/system/kubelet.service.d
            cat > /etc/systemd/system/kubelet.service.d/10-kubeadm.conf <<'DROPIN'
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/local/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS
DROPIN
            _service_reload
            ;;
        openrc)
            cat > /etc/init.d/kubelet <<'INITD'
#!/sbin/openrc-run
name="kubelet"
description="Kubernetes Node Agent"
command="/usr/local/bin/kubelet"
command_args="--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf \
  --kubeconfig=/etc/kubernetes/kubelet.conf \
  --config=/var/lib/kubelet/config.yaml"
command_background=true
pidfile="/run/kubelet.pid"
output_log="/var/log/kubelet.log"
error_log="/var/log/kubelet.log"

depend() {
    need net localmount
    use cgroups
    after containerd crio
}

start_pre() {
    if [ -f /var/lib/kubelet/kubeadm-flags.env ]; then
        . /var/lib/kubelet/kubeadm-flags.env
        command_args="$command_args $KUBELET_KUBEADM_ARGS"
    fi
    if [ -f /etc/default/kubelet ]; then
        . /etc/default/kubelet
        command_args="$command_args $KUBELET_EXTRA_ARGS"
    fi
}
INITD
            chmod +x /etc/init.d/kubelet
            ;;
    esac
}

_k8s_install_binaries() {
    local patch_version
    patch_version=$(_resolve_k8s_patch_version "$K8S_VERSION")
    if [ -z "$patch_version" ]; then
        log_error "Failed to resolve patch version for K8s ${K8S_VERSION}"
        return 1
    fi
    log_info "Resolved Kubernetes version: v${patch_version}"

    # glibc binaries on musl systems
    if [ "${DISTRO_PKG:-}" = apk ]; then
        pkg_install gcompat || log_warn "gcompat could not be installed; glibc binaries may not run"
    fi
    # CRI-O release tarballs bundle CNI plugins
    if [ "$CRI" != "crio" ]; then
        cni_install_binaries || return 1
    fi

    log_info "Downloading Kubernetes binaries v${patch_version}..."
    _install_k8s_binary kubeadm "$patch_version" || return 1
    _install_k8s_binary kubelet "$patch_version" || return 1
    _install_k8s_binary kubectl "$patch_version" || return 1
    # CRI-O release tarballs bundle crictl
    if [ "$CRI" != "crio" ]; then
        _crictl_install_binary "$K8S_VERSION" || return 1
    fi
    _install_kubelet_service
    log_info "Kubernetes v${patch_version} binaries installed to /usr/local/bin/"
}

_k8s_remove_binaries() {
    local bin
    for bin in kubeadm kubectl kubelet crictl; do
        if [ -f "/usr/local/bin/$bin" ]; then
            rm -f "/usr/local/bin/$bin"
            log_info "Removed /usr/local/bin/$bin"
        fi
    done
    rm -f /etc/systemd/system/kubelet.service /etc/init.d/kubelet
    rm -rf /etc/systemd/system/kubelet.service.d
}

# --- interface ---

k8s_install() {
    log_info "Installing Kubernetes ${K8S_VERSION} (source: ${DISTRO_K8S_SOURCE})..."
    case "$DISTRO_K8S_SOURCE" in
        pkgs)
            local v="${K8S_PATCH_VERSION:-$K8S_VERSION}"
            _k8s_remove_conflicting_packages || return 1
            _k8s_repo_add "$K8S_VERSION" || return 1
            if [ "${K8S_PRERELEASE:-false}" = true ]; then
                # The prerelease channel has no cri-tools package
                pkg_install --hold --repo kubernetes \
                    "kubelet=${v}" "kubeadm=${v}" "kubectl=${v}" || return 1
                _crictl_install_binary "$K8S_VERSION" || return 1
            else
                pkg_install --hold --repo kubernetes \
                    "kubelet=${v}" "kubeadm=${v}" "kubectl=${v}" cri-tools || return 1
            fi
            ;;
        distro)
            _k8s_require_distro_version "$K8S_VERSION" || return 1
            _k8s_remove_legacy_packages || return 1
            # shellcheck disable=SC2046 # space-separated package specs
            pkg_install --hold $(_k8s_distro_specs "${K8S_PATCH_VERSION:-$K8S_VERSION}") || return 1
            ;;
        binary)
            _k8s_install_binaries || return 1
            ;;
        *)
            log_error "Unknown Kubernetes source: ${DISTRO_K8S_SOURCE}"
            return 1
            ;;
    esac
    if ! command -v kubeadm >/dev/null 2>&1; then
        log_error "kubeadm is not available after installation"
        return 1
    fi
    _enable_and_start_kubelet
}

# Remove packages of earlier setup-k8s versions that the distribution
# packages replace (they conflict with, or only provide, the same names; for
# example kubeadm-bin replaces kubeadm). Without names, all of them.
# Usage: _k8s_remove_legacy_packages [package...]
_k8s_remove_legacy_packages() {
    [ -n "${DISTRO_K8S_LEGACY_PKGS:-}" ] || return 0
    local legacy name selected=""
    for legacy in $DISTRO_K8S_LEGACY_PKGS; do
        if [ $# -eq 0 ]; then
            selected="${selected} ${legacy}"
            continue
        fi
        for name in "$@"; do
            case "$legacy" in "${name}"-*) selected="${selected} ${legacy}" ;; esac
        done
    done
    # shellcheck disable=SC2086 # space-separated package names
    selected=$(_pkg_filter_installed $selected)
    [ -n "$selected" ] || return 0
    log_info "Replacing packages installed by an earlier setup-k8s version:${selected:+ }${selected}"
    # shellcheck disable=SC2086
    pkg_remove $selected
}

k8s_upgrade_kubeadm() {
    local target="$1"
    log_info "Upgrading kubeadm to v${target}..."
    case "$DISTRO_K8S_SOURCE" in
        pkgs)
            _k8s_repo_add "$(_k8s_minor_version "$target")" || return 1
            pkg_install --hold --repo kubernetes "kubeadm=${target}"
            ;;
        distro)
            _k8s_remove_legacy_packages kubeadm || return 1
            pkg_install --hold "kubeadm=${target}"
            ;;
        binary) _install_k8s_binary kubeadm "$target" ;;
    esac
}

k8s_upgrade_node() {
    local target="$1"
    log_info "Upgrading kubelet and kubectl to v${target}..."
    case "$DISTRO_K8S_SOURCE" in
        pkgs)   pkg_install --hold --repo kubernetes "kubelet=${target}" "kubectl=${target}" cri-tools ;;
        distro)
            _k8s_remove_legacy_packages kubelet kubectl || return 1
            pkg_install --hold "kubelet=${target}" "kubectl=${target}"
            ;;
        binary)
            _install_k8s_binary kubelet "$target" || return 1
            _install_k8s_binary kubectl "$target"
            ;;
    esac
}

# Distribution packages a "distro" install puts on the node (and earlier
# setup-k8s versions did); cni-plugins is kept with --preserve-cni.
k8s_distro_installed_pkgs() {
    local pkg out=""
    for pkg in $_K8S_CORE_PKGS ${DISTRO_K8S_PKGS:-} kubelet-openrc ${DISTRO_K8S_LEGACY_PKGS:-}; do
        [ "$pkg" = cni-plugins ] && [ "${PRESERVE_CNI:-false}" = true ] && continue
        case " $out " in *" $pkg "*) ;; *) out="${out}${out:+ }${pkg}" ;; esac
    done
    echo "$out"
}

k8s_remove() {
    log_info "Removing Kubernetes packages..."
    local rc=0
    case "$DISTRO_K8S_SOURCE" in
        pkgs)
            pkg_remove kubeadm kubectl kubelet kubernetes-cni cri-tools || rc=1
            # kubernetes-apt-keyring: key file name of earlier setup-k8s versions
            pkg_repo_remove kubernetes kubernetes-apt-keyring
            ;;
        distro)
            # shellcheck disable=SC2046 # space-separated package names
            pkg_remove $(k8s_distro_installed_pkgs) || rc=1
            ;;
    esac
    # Binaries may exist from a binary install on any distribution
    _k8s_remove_binaries
    hash -r 2>/dev/null || true
    return "$rc"
}

# --- kubelet helpers ---

# Environment file read by the installed kubelet unit (rpm packages use
# /etc/sysconfig/kubelet, deb packages and binary installs /etc/default/kubelet).
_kubelet_env_file() {
    if grep -rqs 'EnvironmentFile=-/etc/sysconfig/kubelet' \
        /usr/lib/systemd/system/kubelet.service.d /etc/systemd/system/kubelet.service.d 2>/dev/null; then
        echo /etc/sysconfig/kubelet
    else
        echo /etc/default/kubelet
    fi
}

# Configure kubelet node-ip if KUBELET_NODE_IP is set.
_configure_kubelet_node_ip() {
    if [ -n "${KUBELET_NODE_IP:-}" ]; then
        local env_file
        env_file=$(_kubelet_env_file)
        log_info "Setting kubelet node-ip: $KUBELET_NODE_IP ($env_file)"
        mkdir -p "$(dirname "$env_file")"
        echo "KUBELET_EXTRA_ARGS=\"--node-ip=${KUBELET_NODE_IP}\"" > "$env_file"
    fi
}

# Show installed versions
show_versions() {
    log_info "Installed versions:"
    log_info "  $(kubectl version --client 2>&1)"
    log_info "  $(kubeadm version 2>&1)"
}

# Enable and start kubelet service
_enable_and_start_kubelet() {
    _service_enable kubelet
    _service_start kubelet
}
