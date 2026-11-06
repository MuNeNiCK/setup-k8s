#!/bin/sh

# General utilities: user home lookup, confirmation prompt, help footer,
# and cleanup verification.

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
