#!/bin/sh

# containerd.
#
# Source is DISTRO_CONTAINERD_SOURCE:
#   docker  containerd.io from download.docker.com (DISTRO_DOCKER_REPO, DISTRO_CODENAME)
#   distro  distribution packages (DISTRO_CONTAINERD_PKGS)
#   obs     containerd from an openSUSE Build Service project (DISTRO_OBS_REPO)
#   binary  containerd and runc release binaries
#
#   containerd_install   Install, configure, and start containerd
#   containerd_cleanup   Remove repositories and binaries added by containerd_install
#                        (packages are kept; other software may use containerd)

_containerd_from_docker() {
    local base="https://download.docker.com/linux/${DISTRO_DOCKER_REPO}"
    case "$(pkg_format)" in
        deb)
            if [ -z "${DISTRO_CODENAME:-}" ]; then
                log_error "Could not determine the distribution codename for the Docker repository"
                return 1
            fi
            pkg_repo_add docker "$base" "${base}/gpg" "$DISTRO_CODENAME" stable || return 1
            ;;
        rpm)
            # shellcheck disable=SC2016 # $releasever/$basearch are dnf variables
            pkg_repo_add docker "${base}"'/$releasever/$basearch/stable' "${base}/gpg" || return 1
            ;;
        *)
            log_error "The Docker repository provides deb and rpm packages only"
            return 1
            ;;
    esac
    pkg_install --no-weak-deps containerd.io
}

_containerd_from_obs() {
    local base="https://download.opensuse.org/repositories/${DISTRO_OBS_REPO}"
    pkg_repo_add containers "${base}/" "${base}/repodata/repomd.xml.key" || return 1
    pkg_install --repo containers containerd
}

# --- release binaries ---

_install_runc_binary() {
    local arch base
    arch=$(_detect_arch)
    base="https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}"
    _download_with_checksum "${base}/runc.${arch}" /usr/local/bin/runc "${base}/runc.sha256sum" "runc.${arch}" || return 1
    chmod +x /usr/local/bin/runc
}

_install_containerd_binary() {
    local arch version url tmp
    arch=$(_detect_arch)
    version="${CONTAINERD_VERSION}"
    url="https://github.com/containerd/containerd/releases/download/v${version}/containerd-${version}-linux-${arch}.tar.gz"
    tmp=$(mktemp /tmp/containerd-XXXXXX)
    if ! _download_with_checksum "$url" "$tmp" "${url}.sha256sum"; then
        rm -f "$tmp"
        return 1
    fi
    tar --strip-components=1 -C /usr/local/bin/ -xzf "$tmp" \
        bin/containerd bin/containerd-shim-runc-v2 bin/ctr
    rm -f "$tmp"
}

_install_containerd_service() {
    case "$(_detect_init_system)" in
        systemd)
            cat > /etc/systemd/system/containerd.service <<'UNIT'
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
ExecStart=/usr/local/bin/containerd
Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
UNIT
            _service_reload
            ;;
        openrc)
            cat > /etc/init.d/containerd <<'INITD'
#!/sbin/openrc-run
name="containerd"
description="Containerd container runtime"
command="/usr/local/bin/containerd"
command_background=true
pidfile="/run/containerd.pid"
output_log="/var/log/containerd.log"
error_log="/var/log/containerd.log"
depend() { need net localmount; use cgroups; }
INITD
            chmod +x /etc/init.d/containerd
            ;;
    esac
}

_containerd_from_binary() {
    log_info "Installing containerd ${CONTAINERD_VERSION} and runc ${RUNC_VERSION} (binary download)..."
    _install_runc_binary || return 1
    _install_containerd_binary || return 1
    _install_containerd_service
}

# --- interface ---

containerd_install() {
    log_info "Installing containerd (source: ${DISTRO_CONTAINERD_SOURCE})..."
    cri_install_selinux_policy
    case "$DISTRO_CONTAINERD_SOURCE" in
        docker) _containerd_from_docker || return 1 ;;
        obs)    _containerd_from_obs || return 1 ;;
        distro)
            # shellcheck disable=SC2086 # space-separated package names
            pkg_install $DISTRO_CONTAINERD_PKGS || return 1
            ;;
        binary) _containerd_from_binary || return 1 ;;
        *)
            log_error "Unknown containerd source: ${DISTRO_CONTAINERD_SOURCE}"
            return 1
            ;;
    esac
    _finalize_containerd_setup
}

containerd_cleanup() {
    # docker-ce: repository file name of earlier setup-k8s versions (rpm)
    pkg_repo_remove docker docker-ce 2>/dev/null || true
    pkg_repo_remove containers 2>/dev/null || true
    local bin had_binary=false
    [ -f "${_CONTAINERD_BIN_DIR}/containerd" ] && had_binary=true
    for bin in containerd containerd-shim-runc-v2 ctr runc; do
        if [ -f "${_CONTAINERD_BIN_DIR}/$bin" ]; then
            rm -f "${_CONTAINERD_BIN_DIR}/$bin"
            log_info "Removed ${_CONTAINERD_BIN_DIR}/$bin"
        fi
    done
    # The service files of a binary install; with distribution packages they
    # belong to the package (e.g. containerd-openrc), which cleanup keeps
    if [ "$had_binary" = true ]; then
        # shellcheck disable=SC2086 # space-separated paths
        rm -f $_CONTAINERD_SERVICE_FILES
    fi
}

# Locations of a binary containerd install (overridable for tests)
_CONTAINERD_BIN_DIR="/usr/local/bin"
_CONTAINERD_SERVICE_FILES="/etc/systemd/system/containerd.service /etc/init.d/containerd"
