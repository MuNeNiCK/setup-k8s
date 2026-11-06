#!/bin/sh

# Logging module with log level control and optional file logging.
# LOG_LEVEL: 0=quiet (errors only), 1=normal (default), 2=verbose (debug)
# File logging: set _LOG_FILE via _init_file_logging() to persist logs to disk.

# Log file path (empty = no file logging)
_LOG_FILE="${_LOG_FILE:-}"

# Write a line to the log file (if file logging is enabled).
_log_to_file() {
    [ -z "$_LOG_FILE" ] && return 0
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "---")
    printf '%s %s\n' "$ts" "$*" >> "$_LOG_FILE" 2>/dev/null || true
}

log_error() {
    echo "ERROR: $*" >&2
    _log_to_file "ERROR: $*"
}

log_warn() {
    _log_to_file "WARNING: $*"
    if [ "${LOG_LEVEL:-1}" -ge 1 ]; then
        echo "WARNING: $*" >&2
    fi
}

log_info() {
    _log_to_file "INFO: $*"
    if [ "${LOG_LEVEL:-1}" -ge 1 ]; then
        echo "$*" >&2
    fi
}

log_debug() {
    _log_to_file "DEBUG: $*"
    if [ "${LOG_LEVEL:-1}" -ge 2 ]; then
        echo "DEBUG: $*" >&2
    fi
}

# Initialize file logging.
# Creates log directory and opens log file.
# Usage: _init_file_logging [dir]
#   dir: log directory (default: /var/log/setup-k8s)
_init_file_logging() {
    local log_dir="${1:-/var/log/setup-k8s}"

    if ! mkdir -p "$log_dir" 2>/dev/null; then
        echo "WARNING: Cannot create log directory $log_dir, file logging disabled" >&2
        return 0
    fi

    local ts
    ts=$(date '+%Y%m%d-%H%M%S' 2>/dev/null || echo "unknown")
    _LOG_FILE="${log_dir}/setup-k8s-${ts}.log"

    if ! : >> "$_LOG_FILE" 2>/dev/null; then
        echo "WARNING: Cannot write to log file $_LOG_FILE, file logging disabled" >&2
        _LOG_FILE=""
        return 0
    fi

    chmod 600 "$_LOG_FILE" 2>/dev/null || true
    _log_to_file "=== setup-k8s log started ==="
}

# Record a structured audit event.
# Usage: _audit_log <operation> <outcome> [details]
#   operation: e.g., deploy, upgrade, remove, backup, restore, renew
#   outcome:   e.g., started, completed, failed
#   details:   optional free-form details
_audit_log() {
    local operation="$1" outcome="$2" details="${3:-}"
    local ts
    ts=$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || echo "---")
    local user="${SUDO_USER:-$(id -un 2>/dev/null || echo unknown)}"
    local entry="AUDIT: ts=${ts} op=${operation} outcome=${outcome} user=${user}"
    [ -n "$details" ] && entry="${entry} details=${details}"

    # Always log to file
    if [ -n "$_LOG_FILE" ]; then
        printf '%s\n' "$entry" >> "$_LOG_FILE" 2>/dev/null || true
    fi

    # Optionally send to syslog
    if [ "${_AUDIT_SYSLOG:-false}" = true ] && command -v logger >/dev/null 2>&1; then
        logger -t setup-k8s "$entry" 2>/dev/null || true
    fi

    log_debug "$entry"
}
