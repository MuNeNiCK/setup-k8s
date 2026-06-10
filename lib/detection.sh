#!/bin/sh

# Detect Linux distribution
detect_distribution() {
    if [ -n "$DISTRO_OVERRIDE" ]; then
        DISTRO_FAMILY="$DISTRO_OVERRIDE"
        DISTRO_NAME="${DISTRO_OVERRIDE}-manual"
        DISTRO_VERSION="manual"
        log_info "Using manually specified distro family: $DISTRO_FAMILY"
        return 0
    fi

    log_info "Detecting Linux distribution..."

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO_NAME=$ID
        DISTRO_VERSION=${VERSION_ID:-rolling}
    else
        DISTRO_NAME="unknown"
        DISTRO_VERSION="unknown"
    fi

    log_info "Detected distribution: $DISTRO_NAME $DISTRO_VERSION"

    # Set distribution family for easier handling
    case "$DISTRO_NAME" in
        ubuntu|debian)
            DISTRO_FAMILY="debian"
            ;;
        centos|rhel|fedora|rocky|almalinux|ol)
            DISTRO_FAMILY="rhel"
            ;;
        suse|sles|opensuse*)
            DISTRO_FAMILY="suse"
            ;;
        arch|manjaro)
            DISTRO_FAMILY="arch"
            ;;
        alpine)
            DISTRO_FAMILY="alpine"
            ;;
        *)
            DISTRO_FAMILY="unknown"
            ;;
    esac

    # Check if distribution is supported
    case "$DISTRO_FAMILY" in
        debian|rhel|suse|arch|alpine)
            log_info "Distribution $DISTRO_NAME (family: $DISTRO_FAMILY) is supported."
            ;;
        *)
            log_warn "Unsupported distribution $DISTRO_NAME. The script may not work correctly."
            log_warn "Attempting to continue with generic methods, but you may need to manually install some components."
            DISTRO_FAMILY="generic"
            ;;
    esac
}

# Check if the system uses cgroups v2
_has_cgroupv2() {
    [ -f /sys/fs/cgroup/cgroup.controllers ] && return 0
    return 1
}

# Kubernetes 1.35+ makes cgroups v1 fail by default.
_K8S_MIN_CGROUPV2="1.35"

# Determine the latest stable Kubernetes version
determine_k8s_version() {
    if [ -z "$K8S_VERSION" ]; then
        log_info "Determining latest stable Kubernetes minor version..."
        local STABLE_VER
        if ! STABLE_VER=$(curl -fsSL --retry 3 --retry-delay 2 https://dl.k8s.io/release/stable.txt); then
            log_error "Failed to fetch stable Kubernetes version from dl.k8s.io"
            log_error "  Specify explicitly with --kubernetes-version (e.g. --kubernetes-version 1.32)"
            return 1
        fi
        if echo "$STABLE_VER" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+'; then
            K8S_VERSION=$(echo "$STABLE_VER" | sed -E 's/^v([0-9]+\.[0-9]+)\..*/\1/')
            log_info "Using detected stable Kubernetes minor: ${K8S_VERSION}"
        else
            log_error "Unexpected response from dl.k8s.io: $STABLE_VER"
            log_error "  Specify explicitly with --kubernetes-version (e.g. --kubernetes-version 1.32)"
            return 1
        fi
    fi

    # Validate version format (must be X.Y)
    if ! echo "$K8S_VERSION" | grep -qE '^[0-9]+\.[0-9]+$'; then
        log_error "Invalid Kubernetes version format: $K8S_VERSION (expected X.Y, e.g. 1.32)"
        return 1
    fi

    # Compatibility gate: K8s >= _K8S_MIN_CGROUPV2 requires cgroups v2
    if ! _has_cgroupv2; then
        local k8s_minor; k8s_minor=$(echo "$K8S_VERSION" | cut -d. -f2)
        local min_minor; min_minor=$(echo "$_K8S_MIN_CGROUPV2" | cut -d. -f2)
        if [ "$k8s_minor" -ge "$min_minor" ]; then
            local max_supported="1.$(( min_minor - 1 ))"
            log_error "Kubernetes ${K8S_VERSION} requires cgroups v2, but this system uses cgroups v1."
            log_error "  Distro: ${DISTRO_NAME:-unknown} ${DISTRO_VERSION:-unknown}"
            log_error "  Options:"
            log_error "    1. Migrate to cgroups v2 (recommended)"
            log_error "    2. Use --kubernetes-version ${max_supported} (last version supporting cgroups v1)"
            return 1
        fi
    fi
}
