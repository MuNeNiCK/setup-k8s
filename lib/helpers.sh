#!/bin/sh

# Helpers: kubelet, downloads, package verification, and UI utilities.
# CRI helpers (containerd, CRI-O, crictl) → lib/cri_helpers.sh
# System detection / service abstraction → lib/system.sh
# kubectl / kube-vip helpers → lib/kubevip.sh

# Configure kubelet node-ip if KUBELET_NODE_IP is set.
_configure_kubelet_node_ip() {
    if [ -n "${KUBELET_NODE_IP:-}" ]; then
        log_info "Setting kubelet node-ip: $KUBELET_NODE_IP"
        mkdir -p /etc/default
        echo "KUBELET_EXTRA_ARGS=\"--node-ip=${KUBELET_NODE_IP}\"" > /etc/default/kubelet
    fi
}

# === Download Helpers ===

_download_binary() {
    local url="$1" dest="$2"
    log_info "Downloading: $url"
    if ! curl -fsSL --retry 3 --retry-delay 2 -o "$dest" "$url"; then
        log_error "Failed to download: $url"
        return 1
    fi
    chmod +x "$dest"
}

# Checksum-verified download (verification is best-effort)
# Usage: _download_with_checksum <url> <dest> [checksum_url]
_download_with_checksum() {
    local url="$1" dest="$2" checksum_url="${3:-}"
    _download_binary "$url" "$dest"
    if [ -n "$checksum_url" ]; then
        local expected actual
        if expected=$(curl -fsSL "$checksum_url" 2>/dev/null); then
            expected=$(echo "$expected" | awk '{print $1}')
            actual=$(sha256sum "$dest" | awk '{print $1}')
            if [ "$expected" != "$actual" ]; then
                log_error "Checksum mismatch for $dest"
                rm -f "$dest"
                return 1
            fi
            log_info "Checksum verified: $(basename "$dest")"
        fi
    fi
}

# Helper: Get the home directory for a given user (portable, no hardcoded /home)
get_user_home() {
    local user="$1"
    case "$user" in
        *[!a-zA-Z0-9._-]*)
            log_error "Invalid username: $user"
            return 1
            ;;
    esac
    local home
    home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6) || true
    if [ -z "$home" ]; then
        if [ "$user" = "root" ]; then home="/root"
        else home="/home/$user"
        fi
    fi
    echo "$home"
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

# Check which packages remain installed after cleanup.
# Usage: _verify_packages_removed <check_cmd> <pkg1> [pkg2] ...
#   check_cmd: command that returns 0 if package is installed (receives pkg name as $1)
#   Returns: 0 if none remain, 1 if some remain (also logs warnings)
_verify_packages_removed() {
    local _pkg_check_cmd="$1"; shift
    local _remaining=0
    for _pkg in "$@"; do
        if eval "$_pkg_check_cmd '$_pkg'" >/dev/null 2>&1; then
            log_warn "Package still installed: $_pkg"
            _remaining=1
        fi
    done
    echo "$_remaining"
}

# --- UI / confirmation helpers (moved from validation.sh) ---

# Generic destructive-action confirmation prompt.
# Skips if FORCE=true.  Handles non-interactive terminals (reads /dev/tty).
# Usage: _confirm_destructive_action
#   Caller should print its own warning messages before calling this.
_confirm_destructive_action() {
    if [ "$FORCE" = true ]; then
        return 0
    fi
    echo "Are you sure you want to continue? (y/N)"
    if [ -t 0 ]; then
        read -r response
    elif [ -r /dev/tty ]; then
        read -r response < /dev/tty || {
            log_error "Non-interactive environment detected. Use --force to skip confirmation."
            exit 1
        }
    else
        log_error "Non-interactive environment detected. Use --force to skip confirmation."
        exit 1
    fi
    case "$response" in
        [yY]) ;;
        *)
            echo "Operation cancelled."
            exit 0
            ;;
    esac
}

# Print common help footer (--dry-run, --verbose, --quiet, --help).
# Usage: _show_help_footer [indent] [dry_run_description]
_show_help_footer() {
    local p="${1:-  }" dry_run_desc="${2:-}"
    [ -n "$dry_run_desc" ] && echo "${p}--dry-run               ${dry_run_desc}"
    echo "${p}--verbose               Enable debug logging"
    echo "${p}--quiet                 Suppress informational messages"
    echo "${p}--help                  Display this help message"
}

# Unified cleanup verification: check remaining files and report.
# Usage: _verify_cleanup <remaining_from_pkg_check> <file1> [file2] ...
_verify_cleanup() {
    local remaining="$1"; shift
    log_info "Verifying cleanup..."
    for file in "$@"; do
        if [ -f "$file" ]; then
            log_warn "File still exists: $file"
            remaining=1
        fi
    done
    if [ "$remaining" -ne 0 ]; then
        log_warn "Some files or packages could not be removed. You may want to remove them manually."
        return 1
    fi
    log_info "All specified components have been successfully removed."
}

# Common pre-cleanup steps shared by all distributions
cleanup_pre_common() {
    log_info "Resetting cluster state..."
    kubeadm reset -f || true
    cleanup_cni
}

# Build sudo prefix for non-root remote execution.
# Usage: local pfx; pfx=$(_sudo_prefix "$user")
_sudo_prefix() {
    if [ "$1" != "root" ]; then
        printf 'sudo -n '
    fi
}

# Extract MAJOR.MINOR from a version string (e.g., "1.32.5" → "1.32").
_k8s_minor_version() { echo "$1" | cut -d. -f1,2; }

# Check if an argument is the --distro flag.
_is_distro_flag() { [ "$1" = "--distro" ]; }

# Parse --distro flag: validate and shift.
# Sets DISTRO_FAMILY/DISTRO_OVERRIDE. Caller must shift $_DISTRO_SHIFT.
_DISTRO_SHIFT=0
_parse_distro_flag() {
    _require_value "$1" "$2" "${3:-}"
    _parse_distro_arg "$3"
    _DISTRO_SHIFT=2
}
