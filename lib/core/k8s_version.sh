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
#   swap                 NodeSwap with LimitedSwap enabled by default (kubelet failSwapOn: false)
#   nftables             kube-proxy nftables mode (alpha)
#   nftables-beta        kube-proxy nftables mode beta
#   nftables-ga          kube-proxy nftables mode GA (used by --proxy-mode auto)
#   super-admin-conf     kubeadm writes super-admin.conf (used by kube-vip during init)
#   ipvs-deprecated      kube-proxy ipvs mode deprecated
#   cgroupv2-required    kubelet fails on cgroups v1 by default
#   containerd-v2-required  kubelet no longer supports containerd 1.x
#   selinux-mount        SELinuxMount GA: volumes relabeled with mount options
#   user-namespaces      UserNamespacesSupport GA (Pods with hostUsers: false)
_K8S_FEATURE_MINIMUMS="swap=1.30
nftables=1.29
nftables-beta=1.31
nftables-ga=1.33
super-admin-conf=1.29
ipvs-deprecated=1.35
cgroupv2-required=1.35
containerd-v2-required=1.38
selinux-mount=1.37
user-namespaces=1.36"

# Fallback pause image tag when kubeadm cannot report it.
_K8S_PAUSE_FALLBACK="3.10.2"

# A prerelease version (1.38.0-alpha.1, -beta.0, -rc.1)
k8s_is_prerelease() { case "$1" in *-*) return 0 ;; esac; return 1; }

# Use the prerelease channels (pkgs.k8s.io, isv:cri-o, dl.k8s.io latest-*)
# when the requested version is a prerelease or its minor has no stable
# release yet. Usage: k8s_select_channel <MAJOR.MINOR> [exact_version]
k8s_select_channel() {
    local minor="$1" exact="${2:-}" stable
    K8S_PRERELEASE=false
    if [ -n "$exact" ]; then
        k8s_is_prerelease "$exact" && K8S_PRERELEASE=true
    else
        stable=$(curl -fsSL --retry 3 --retry-delay 2 https://dl.k8s.io/release/stable.txt) || {
            log_error "Failed to fetch the stable Kubernetes version from dl.k8s.io"
            return 1
        }
        k8s_version_ge "$minor" "$(_k8s_minor_version "$stable")" && [ "$minor" != "$(_k8s_minor_version "$stable")" ] \
            && K8S_PRERELEASE=true
    fi
    if [ "$K8S_PRERELEASE" = true ]; then
        log_warn "Kubernetes ${exact:-$minor} is not released yet: installing from the prerelease channels (for testing)"
    fi
}

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

# Print the pause image for the installed kubeadm (honoring
# --image-repository). PAUSE_IMAGE_VERSION overrides the tag.
k8s_pause_image() {
    local tag="${PAUSE_IMAGE_VERSION:-}" kubeadm_version image
    if [ -z "$tag" ] && command -v kubeadm >/dev/null 2>&1; then
        kubeadm_version=$(kubeadm version -o short 2>/dev/null) || kubeadm_version=""
        if [ -n "$kubeadm_version" ]; then
            if [ -n "${KUBEADM_IMAGE_REPOSITORY:-}" ]; then
                image=$(kubeadm config images list --kubernetes-version "$kubeadm_version" \
                    --image-repository "$KUBEADM_IMAGE_REPOSITORY" 2>/dev/null | grep '/pause:' | head -n 1)
            else
                image=$(kubeadm config images list --kubernetes-version "$kubeadm_version" 2>/dev/null | grep '/pause:' | head -n 1)
            fi
            tag="${image##*:}"
        fi
    fi
    if [ -n "${image:-}" ] && [ -z "${PAUSE_IMAGE_VERSION:-}" ]; then
        echo "$image"
        return 0
    fi
    if [ -z "$tag" ]; then
        tag="$_K8S_PAUSE_FALLBACK"
        log_warn "Could not determine the pause image from kubeadm; using pause:${tag}"
    fi
    echo "${KUBEADM_IMAGE_REPOSITORY:-registry.k8s.io}/pause:${tag}"
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
    if [ -n "$K8S_VERSION" ] && [ "${DISTRO_K8S_SOURCE:-}" != distro ]; then
        k8s_select_channel "$K8S_VERSION" "${K8S_PATCH_VERSION:-}" || return 1
    fi
    if [ -z "$K8S_VERSION" ]; then
        local marker=stable
        log_info "Determining the latest ${marker} Kubernetes minor version..."
        local STABLE_VER
        if ! STABLE_VER=$(curl -fsSL --retry 3 --retry-delay 2 "https://dl.k8s.io/release/${marker}.txt"); then
            log_error "Failed to fetch stable Kubernetes version from dl.k8s.io"
            log_error "  Specify explicitly with --kubernetes-version (e.g. --kubernetes-version 1.37)"
            return 1
        fi
        if echo "$STABLE_VER" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+'; then
            K8S_VERSION=$(_k8s_minor_version "$STABLE_VER")
            log_info "Using detected ${marker} Kubernetes minor: ${K8S_VERSION}"
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
        log_warn "This node uses cgroups v1, which Kubernetes ${K8S_VERSION} has deprecated; kubelet runs with failCgroupV1: false."
        log_warn "  Migrate the node to cgroups v2: a later Kubernetes release removes cgroups v1 support."
    fi
}
