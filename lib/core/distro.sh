#!/bin/sh
# shellcheck disable=SC2034 # DISTRO_* values are read by other modules

# Distribution detection and per-distribution values.
#
# This is the only module that knows distribution names. detect_distribution
# reads /etc/os-release and sets plain values that other modules use; they
# branch on these values, the package manager, or observed state, never on
# the distribution name.
#
#   DISTRO_NAME, DISTRO_VERSION   os-release ID and VERSION_ID
#   DISTRO_FAMILY                 debian, rhel, suse, alpine, arch, or generic
#   DISTRO_PKG                    package manager adapter: apt, dnf, zypper, apk, pacman ("" if none)
#   DISTRO_K8S_SOURCE             kubeadm/kubelet/kubectl: pkgs (pkgs.k8s.io), distro, or binary
#   DISTRO_CONTAINERD_SOURCE      docker (download.docker.com), distro, obs, or binary
#   DISTRO_CRIO_SOURCE            isv (isv:cri-o on OBS), distro, or binary
#   DISTRO_DOCKER_REPO            path segment on download.docker.com (ubuntu, debian, fedora, centos, rhel)
#   DISTRO_CODENAME               apt suite for the Docker repository
#   DISTRO_OBS_REPO               OBS project path for the obs containerd source
#   DISTRO_K8S_PKGS               package names for the distro Kubernetes source
#   DISTRO_K8S_LEGACY_PKGS        packages installed by earlier setup-k8s versions
#                                 that the distro packages replace (removed first)
#   DISTRO_CONTAINERD_PKGS        package names for the distro containerd source
#   DISTRO_CRIO_PKGS              package names for the distro CRI-O source
#   DISTRO_KMOD_PKG               package that provides br_netfilter when the module is missing

# os-release file to read (overridable for tests)
_OS_RELEASE_FILE="/etc/os-release"

# Map an os-release ID (or one ID_LIKE entry) to a family. Prints nothing
# when the ID is unknown.
_distro_family_of() {
    case "$1" in
        ubuntu|debian) echo debian ;;
        rhel|centos|fedora|rocky|almalinux|ol) echo rhel ;;
        opensuse*|sles|suse|sle-micro) echo suse ;;
        arch|manjaro) echo arch ;;
        alpine) echo alpine ;;
    esac
}

# Set the values for a family. Uses os-release fields loaded by
# detect_distribution (ID, VERSION_ID, ID_LIKE, VERSION_CODENAME,
# UBUNTU_CODENAME).
_distro_apply_family() {
    DISTRO_FAMILY="$1"
    DISTRO_PKG=""
    DISTRO_K8S_SOURCE=binary
    DISTRO_CONTAINERD_SOURCE=binary
    DISTRO_CRIO_SOURCE=binary
    DISTRO_DOCKER_REPO=""
    DISTRO_CODENAME=""
    DISTRO_OBS_REPO=""
    DISTRO_K8S_PKGS=""
    DISTRO_K8S_LEGACY_PKGS=""
    DISTRO_CONTAINERD_PKGS=""
    DISTRO_CRIO_PKGS=""
    DISTRO_KMOD_PKG=""

    case "$DISTRO_FAMILY" in
        debian)
            DISTRO_PKG=apt
            DISTRO_K8S_SOURCE=pkgs
            DISTRO_CONTAINERD_SOURCE=docker
            DISTRO_CRIO_SOURCE=isv
            if [ "${ID:-}" = ubuntu ] || [ -n "${UBUNTU_CODENAME:-}" ]; then
                DISTRO_DOCKER_REPO=ubuntu
                DISTRO_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
            else
                DISTRO_DOCKER_REPO=debian
                DISTRO_CODENAME="${VERSION_CODENAME:-}"
            fi
            ;;
        rhel)
            DISTRO_PKG=dnf
            DISTRO_K8S_SOURCE=pkgs
            DISTRO_CONTAINERD_SOURCE=docker
            DISTRO_CRIO_SOURCE=isv
            DISTRO_KMOD_PKG="kernel-modules-extra-$(uname -r)"
            case "${ID:-}" in
                fedora) DISTRO_DOCKER_REPO=fedora ;;
                centos) DISTRO_DOCKER_REPO=centos ;;
                *)      DISTRO_DOCKER_REPO=rhel ;;
            esac
            ;;
        suse)
            DISTRO_PKG=zypper
            DISTRO_K8S_SOURCE=pkgs
            DISTRO_CRIO_SOURCE=isv
            case "${ID:-}" in
                opensuse-leap)
                    # The distribution's containerd is 1.7; use the openSUSE
                    # container tools project for a current release.
                    DISTRO_CONTAINERD_SOURCE=obs
                    DISTRO_OBS_REPO="Virtualization:/containers/${VERSION_ID:-16.0}"
                    ;;
                *)
                    DISTRO_CONTAINERD_SOURCE=distro
                    DISTRO_CONTAINERD_PKGS="containerd"
                    ;;
            esac
            ;;
        alpine)
            DISTRO_PKG=apk
            DISTRO_K8S_SOURCE=distro
            DISTRO_CONTAINERD_SOURCE=distro
            DISTRO_CRIO_SOURCE=distro
            DISTRO_K8S_PKGS="kubeadm kubelet kubectl kubelet-openrc cni-plugins cri-tools"
            DISTRO_CONTAINERD_PKGS="containerd containerd-openrc"
            DISTRO_CRIO_PKGS="cri-o cri-o-openrc"
            ;;
        arch)
            DISTRO_PKG=pacman
            DISTRO_K8S_SOURCE=distro
            DISTRO_CONTAINERD_SOURCE=distro
            DISTRO_CRIO_SOURCE=distro
            DISTRO_K8S_PKGS="kubeadm kubelet kubectl crictl cni-plugins"
            # Earlier setup-k8s versions installed these from the AUR
            DISTRO_K8S_LEGACY_PKGS="kubeadm-bin kubelet-bin kubectl-bin"
            DISTRO_CONTAINERD_PKGS="containerd"
            DISTRO_CRIO_PKGS="iptables-nft cri-o"
            ;;
        generic)
            DISTRO_PKG=$(_pkg_detect_manager)
            ;;
    esac
}

# Detect the Linux distribution and set the DISTRO_* values.
detect_distribution() {
    log_info "Detecting Linux distribution..."

    ID="" VERSION_ID="" ID_LIKE="" VERSION_CODENAME="" UBUNTU_CODENAME=""
    if [ -f "$_OS_RELEASE_FILE" ]; then
        # shellcheck source=/dev/null
        . "$_OS_RELEASE_FILE"
    fi
    DISTRO_NAME="${ID:-unknown}"
    DISTRO_VERSION="${VERSION_ID:-rolling}"
    log_info "Detected distribution: $DISTRO_NAME $DISTRO_VERSION"

    local family _like
    if [ -n "$DISTRO_OVERRIDE" ]; then
        family="$DISTRO_OVERRIDE"
        log_info "Using manually specified distro family: $family"
    else
        family=$(_distro_family_of "$DISTRO_NAME")
        if [ -z "$family" ]; then
            for _like in ${ID_LIKE:-}; do
                family=$(_distro_family_of "$_like")
                if [ -n "$family" ]; then
                    log_warn "$DISTRO_NAME is not tested; using the $family family based on ID_LIKE=\"$ID_LIKE\""
                    break
                fi
            done
        fi
        if [ -z "$family" ]; then
            log_warn "Unsupported distribution $DISTRO_NAME. The script may not work correctly."
            log_warn "Attempting to continue with generic methods, but you may need to manually install some components."
            family=generic
        else
            log_info "Distribution $DISTRO_NAME (family: $family) is supported."
        fi
    fi

    _distro_apply_family "$family"
}
