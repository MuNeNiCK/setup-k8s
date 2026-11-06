#!/bin/sh

# Kubernetes version knowledge: version resolution, comparison, the minimum
# version of each version-dependent behavior, and images derived from the
# installed release.
#
#   determine_k8s_version            Set K8S_VERSION (MAJOR.MINOR) and validate it
#   k8s_version_ge <version> <min>   Succeed when MAJOR.MINOR of version >= min
#   k8s_feature_min <feature>        Print the minimum Kubernetes minor for a feature
#   k8s_supports <feature> [version] Succeed when version (default K8S_VERSION) >= the feature minimum
#   k8s_pause_image                  Print the pause image for the installed kubeadm
#   _k8s_minor_version <version>     Print MAJOR.MINOR

# Minimum Kubernetes minor version per feature.
#   swap                 NodeSwap with LimitedSwap (kubelet failSwapOn: false)
#   nftables             kube-proxy nftables mode (alpha)
#   nftables-beta        kube-proxy nftables mode beta
#   super-admin-conf     kubeadm writes super-admin.conf (used by kube-vip during init)
#   ipvs-deprecated      kube-proxy ipvs mode deprecated
#   cgroupv2-required    kubelet fails on cgroups v1 by default
#   containerd-v2-required  containerd 1.x is no longer supported
_K8S_FEATURE_MINIMUMS="swap=1.28
nftables=1.29
nftables-beta=1.31
super-admin-conf=1.29
ipvs-deprecated=1.35
cgroupv2-required=1.35
containerd-v2-required=1.36"

# Fallback pause image tag when kubeadm cannot report it.
_K8S_PAUSE_FALLBACK="3.10.2"

# Extract MAJOR.MINOR from a version string (e.g., "1.32.5" -> "1.32").
_k8s_minor_version() { echo "$1" | sed 's/^v//' | cut -d. -f1,2; }

k8s_version_ge() {
    local v m vmaj vmin mmaj mmin
    v=$(_k8s_minor_version "$1")
    m=$(_k8s_minor_version "$2")
    vmaj="${v%%.*}"; vmin="${v#*.}"
    mmaj="${m%%.*}"; mmin="${m#*.}"
    case "$vmaj$vmin$mmaj$mmin" in
        *[!0-9]*|"") return 1 ;;
    esac
    [ "$vmaj" -gt "$mmaj" ] && return 0
    [ "$vmaj" -eq "$mmaj" ] && [ "$vmin" -ge "$mmin" ]
}

k8s_feature_min() {
    local min
    min=$(printf '%s\n' "$_K8S_FEATURE_MINIMUMS" | sed -n "s/^$1=//p")
    if [ -z "$min" ]; then
        log_error "Unknown Kubernetes feature: $1"
        return 1
    fi
    echo "$min"
}

k8s_supports() {
    local feature="$1" version="${2:-$K8S_VERSION}" min
    min=$(k8s_feature_min "$feature") || return 1
    k8s_version_ge "$version" "$min"
}

# Print the pause image (registry.k8s.io/pause:<tag>) for the installed
# kubeadm. PAUSE_IMAGE_VERSION overrides the tag.
k8s_pause_image() {
    local tag="${PAUSE_IMAGE_VERSION:-}" kubeadm_version image
    if [ -z "$tag" ] && command -v kubeadm >/dev/null 2>&1; then
        kubeadm_version=$(kubeadm version -o short 2>/dev/null) || kubeadm_version=""
        if [ -n "$kubeadm_version" ]; then
            image=$(kubeadm config images list --kubernetes-version "$kubeadm_version" 2>/dev/null | grep '/pause:' | head -n 1)
            tag="${image##*:}"
        fi
    fi
    if [ -z "$tag" ]; then
        tag="$_K8S_PAUSE_FALLBACK"
        log_warn "Could not determine the pause image from kubeadm; using pause:${tag}"
    fi
    echo "registry.k8s.io/pause:${tag}"
}

# Check if the system uses cgroups v2
_has_cgroupv2() {
    [ -f /sys/fs/cgroup/cgroup.controllers ] && return 0
    return 1
}

# Determine the Kubernetes minor version to install: the requested one, the
# version shipped by the distribution when Kubernetes comes from distribution
# packages, or the latest stable release.
determine_k8s_version() {
    if [ -z "$K8S_VERSION" ] && [ "${DISTRO_K8S_SOURCE:-}" = distro ]; then
        K8S_VERSION=$(k8s_distro_minor_version) || K8S_VERSION=""
        if [ -n "$K8S_VERSION" ]; then
            log_info "Using the Kubernetes minor version provided by ${DISTRO_NAME:-the distribution}: ${K8S_VERSION}"
        fi
    fi
    if [ -z "$K8S_VERSION" ]; then
        log_info "Determining latest stable Kubernetes minor version..."
        local STABLE_VER
        if ! STABLE_VER=$(curl -fsSL --retry 3 --retry-delay 2 https://dl.k8s.io/release/stable.txt); then
            log_error "Failed to fetch stable Kubernetes version from dl.k8s.io"
            log_error "  Specify explicitly with --kubernetes-version (e.g. --kubernetes-version 1.37)"
            return 1
        fi
        if echo "$STABLE_VER" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+'; then
            K8S_VERSION=$(_k8s_minor_version "$STABLE_VER")
            log_info "Using detected stable Kubernetes minor: ${K8S_VERSION}"
        else
            log_error "Unexpected response from dl.k8s.io: $STABLE_VER"
            log_error "  Specify explicitly with --kubernetes-version (e.g. --kubernetes-version 1.37)"
            return 1
        fi
    fi

    # Validate version format (must be X.Y)
    if ! echo "$K8S_VERSION" | grep -qE '^[0-9]+\.[0-9]+$'; then
        log_error "Invalid Kubernetes version format: $K8S_VERSION (expected X.Y, e.g. 1.37)"
        return 1
    fi

    if ! _has_cgroupv2 && k8s_supports cgroupv2-required; then
        local min max_supported
        min=$(k8s_feature_min cgroupv2-required)
        max_supported="${min%%.*}.$(( ${min#*.} - 1 ))"
        log_error "Kubernetes ${K8S_VERSION} requires cgroups v2, but this system uses cgroups v1."
        log_error "  Distro: ${DISTRO_NAME:-unknown} ${DISTRO_VERSION:-unknown}"
        log_error "  Options:"
        log_error "    1. Migrate to cgroups v2 (recommended)"
        log_error "    2. Use --kubernetes-version ${max_supported} (last version supporting cgroups v1)"
        return 1
    fi
}
