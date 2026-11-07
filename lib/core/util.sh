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

