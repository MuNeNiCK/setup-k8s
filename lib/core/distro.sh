#!/bin/sh

# Distribution detection.

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

# Helper: Get Debian/Ubuntu codename without lsb_release
get_debian_codename() {
    . /etc/os-release
    if [ -n "${VERSION_CODENAME:-}" ]; then
        echo "$VERSION_CODENAME"
        return 0
    fi
    if [ -n "${UBUNTU_CODENAME:-}" ]; then
        echo "$UBUNTU_CODENAME"
        return 0
    fi
    log_error "Could not determine Debian/Ubuntu codename from /etc/os-release"
    return 1
}
