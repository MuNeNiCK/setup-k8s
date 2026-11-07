#!/bin/sh

# CRI-O.
#
# Source is DISTRO_CRIO_SOURCE:
#   isv     isv:cri-o stable repository on download.opensuse.org (deb/rpm),
#           matching the Kubernetes minor version
#   distro  distribution packages (DISTRO_CRIO_PKGS)
#   binary  CRI-O release tarball (bundles conmon, runc, crun, crictl, CNI plugins)
#
#   crio_install   Install, configure, and start CRI-O
#   crio_remove    Remove packages, repository, and binaries

_crio_from_isv() {
    local series base
    series=$(_k8s_minor_version "$K8S_VERSION")
    local channel=stable
    [ "${K8S_PRERELEASE:-false}" = true ] && channel=prerelease
    base="https://download.opensuse.org/repositories/isv:/cri-o:/${channel}:/v${series}"
    case "$(pkg_format)" in
        deb) pkg_repo_add cri-o "${base}/deb/" "${base}/deb/Release.key" || return 1 ;;
        rpm) pkg_repo_add cri-o "${base}/rpm/" "${base}/rpm/repodata/repomd.xml.key" || return 1 ;;
        *)
            log_error "The isv:cri-o repository provides deb and rpm packages only"
            return 1
            ;;
    esac
    pkg_install --repo cri-o cri-o
}

# --- release tarball ---

_install_crio_tarball() {
    local arch version url tmp extract_dir crio_dir bin src cni_dir etc_dir
    arch=$(_detect_arch)
    version="${CRIO_VERSION}"
    url="https://storage.googleapis.com/cri-o/artifacts/cri-o.${arch}.v${version}.tar.gz"
    tmp=$(mktemp /tmp/cri-o-XXXXXX)
    extract_dir=$(mktemp -d /tmp/cri-o-extract-XXXXXX)

    if ! _download_with_checksum "$url" "$tmp" "${url}.sha256sum"; then
        rm -rf "$tmp" "$extract_dir"
        return 1
    fi
    if ! tar -xzf "$tmp" -C "$extract_dir"; then
        log_error "Failed to extract ${url}"
        rm -rf "$tmp" "$extract_dir"
        return 1
    fi
    rm -f "$tmp"

    crio_dir=$(find "$extract_dir" -maxdepth 1 -type d -name 'cri-o' | head -1)
    [ -n "$crio_dir" ] || crio_dir="$extract_dir"

    local missing=""
    for bin in crio conmon conmonrs runc crun crictl; do
        src=$(find "$crio_dir" -name "$bin" -type f 2>/dev/null | head -1)
        if [ -n "$src" ]; then
            if ! install -m 0755 "$src" "/usr/local/bin/$bin"; then
                log_error "Failed to install /usr/local/bin/$bin"
                rm -rf "$extract_dir"
                return 1
            fi
            log_info "  Installed $bin to /usr/local/bin/"
        fi
    done
    # Required: CRI-O, conmon, an OCI runtime, and crictl
    for bin in crio conmon crictl; do
        [ -x "/usr/local/bin/$bin" ] || missing="${missing} ${bin}"
    done
    if [ ! -x /usr/local/bin/crun ] && [ ! -x /usr/local/bin/runc ]; then
        missing="${missing} crun/runc"
    fi

    mkdir -p /opt/cni/bin
    cni_dir=$(find "$crio_dir" -type d -name 'cni-plugins' 2>/dev/null | head -1)
    if [ -n "$cni_dir" ] && ! install -m 0755 "$cni_dir"/* /opt/cni/bin/; then
        log_error "Failed to install the CNI plugins to /opt/cni/bin/"
        rm -rf "$extract_dir"
        return 1
    fi
    for bin in bridge loopback host-local portmap; do
        [ -x "/opt/cni/bin/$bin" ] || missing="${missing} cni:${bin}"
    done

    mkdir -p /etc/crio/crio.conf.d /etc/containers
    etc_dir=$(find "$crio_dir" -type d -name 'etc' 2>/dev/null | head -1)
    if [ -n "$etc_dir" ]; then
        if ! find "$etc_dir" -name '*.conf' -exec cp {} /etc/crio/crio.conf.d/ \;; then
            log_error "Failed to install the CRI-O configuration"
            rm -rf "$extract_dir"
            return 1
        fi
        if [ -f "$etc_dir/containers/policy.json" ] && ! cp "$etc_dir/containers/policy.json" /etc/containers/; then
            log_error "Failed to install /etc/containers/policy.json"
            rm -rf "$extract_dir"
            return 1
        fi
    fi
    rm -rf "$extract_dir"
    if [ ! -f /etc/containers/policy.json ]; then
        missing="${missing} /etc/containers/policy.json"
    fi
    if [ -n "$missing" ]; then
        log_error "The CRI-O release tarball did not provide:${missing}"
        return 1
    fi
}

_crio_artifact_available() {
    local version="$1" arch url
    arch=$(_detect_arch)
    url="https://storage.googleapis.com/cri-o/artifacts/cri-o.${arch}.v${version}.tar.gz.sha256sum"
    curl -fsI --retry 2 --connect-timeout 5 --max-time 10 "$url" >/dev/null 2>&1
}

_resolve_crio_tarball_version() {
    local patch_version fallback_version
    patch_version=$(_resolve_k8s_patch_version "$K8S_VERSION")
    if [ -n "$patch_version" ] && _crio_artifact_available "$patch_version"; then
        echo "$patch_version"
        return 0
    fi
    fallback_version="${K8S_VERSION}.0"
    if _crio_artifact_available "$fallback_version"; then
        [ -n "$patch_version" ] && log_warn "CRI-O artifact v${patch_version} not found; using v${fallback_version}"
        echo "$fallback_version"
        return 0
    fi
    return 1
}

_install_crio_service() {
    case "$(_detect_init_system)" in
        systemd)
            cat > /etc/systemd/system/crio.service <<'UNIT'
[Unit]
Description=Container Runtime Interface for OCI (CRI-O)
Documentation=https://github.com/cri-o/cri-o
Wants=network-online.target
After=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/crio
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Restart=always
RestartSec=5
LimitNOFILE=65536
LimitNPROC=infinity
LimitCORE=infinity
OOMScoreAdjust=-999
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
UNIT
            _service_reload
            ;;
        openrc)
            cat > /etc/init.d/crio <<'INITD'
#!/sbin/openrc-run
name="crio"
description="Container Runtime Interface for OCI"
command="/usr/local/bin/crio"
command_background=true
pidfile="/run/crio.pid"
output_log="/var/log/crio.log"
error_log="/var/log/crio.log"
depend() { need net localmount; use cgroups; }
INITD
            chmod +x /etc/init.d/crio
            ;;
    esac
}

_crio_from_binary() {
    if [ -z "$CRIO_VERSION" ]; then
        CRIO_VERSION=$(_resolve_crio_tarball_version) || CRIO_VERSION=""
    fi
    if [ -z "$CRIO_VERSION" ]; then
        log_error "Failed to resolve CRI-O version for Kubernetes ${K8S_VERSION}"
        return 1
    fi
    log_info "Installing CRI-O ${CRIO_VERSION} (tarball download)..."
    _install_crio_tarball || return 1
    _install_crio_service
}

# --- interface ---

crio_install() {
    log_info "Installing CRI-O (source: ${DISTRO_CRIO_SOURCE})..."
    cri_install_selinux_policy
    case "$DISTRO_CRIO_SOURCE" in
        isv) _crio_from_isv || return 1 ;;
        distro)
            # shellcheck disable=SC2086 # space-separated package names
            pkg_install $DISTRO_CRIO_PKGS || return 1
            ;;
        binary) _crio_from_binary || return 1 ;;
        *)
            log_error "Unknown CRI-O source: ${DISTRO_CRIO_SOURCE}"
            return 1
            ;;
    esac

    _crio_prepare_config
    _finalize_crio_setup
}

# Write the Kubernetes drop-in (cgroup manager, pause image). Some packages
# ship no configuration, so generate the defaults first.
_crio_prepare_config() {
    if [ ! -f /etc/crio/crio.conf ] && [ -z "$(ls /etc/crio/crio.conf.d 2>/dev/null)" ]; then
        mkdir -p /etc/crio
        crio config > /etc/crio/crio.conf 2>/dev/null || log_warn "Failed to generate CRI-O default config"
    fi
    if [ "$(_detect_init_system)" = "systemd" ]; then
        _write_crio_config "02-kubernetes.conf" "systemd"
    else
        _write_crio_config "02-kubernetes.conf" "cgroupfs"
    fi
    mkdir -p /etc/cni/net.d
}

crio_remove() {
    local rc=0 bin had_binary=false
    if [ -n "${DISTRO_PKG:-}" ]; then
        # Only CRI-O itself; shared tools (conmon, crun, iptables-nft) may be
        # used by other software and are left to the package manager.
        pkg_remove cri-o cri-o-openrc cri-o-runc || rc=1
        # crio-apt-keyring: key file name of earlier setup-k8s versions
        pkg_repo_remove cri-o crio-apt-keyring 2>/dev/null || true
    fi
    [ -f /usr/local/bin/crio ] && had_binary=true
    for bin in crio conmon conmonrs crun crictl; do
        if [ -f "/usr/local/bin/$bin" ]; then
            rm -f "/usr/local/bin/$bin"
            log_info "Removed /usr/local/bin/$bin"
        fi
    done
    rm -f /etc/systemd/system/crio.service /etc/init.d/crio
    if [ "$had_binary" = true ]; then
        rm -rf /etc/crio /etc/containers
    fi
    return "$rc"
}
