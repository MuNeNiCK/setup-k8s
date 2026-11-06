#!/bin/sh

# SSH argument parsing, validation, and node address normalization.
# Transport -> lib/remote/ssh.sh | Session management -> lib/remote/session.sh

# --- SSH common helpers (moved from validation.sh) ---

# Print common SSH options help text.
# Usage: _show_common_ssh_help [indent]
#   indent: prefix string for each line (default: "  ")
_show_common_ssh_help() {
    local p="${1:-  }"
    echo "${p}--ssh-user USER         Default SSH user (default: root)"
    echo "${p}--ssh-port PORT         SSH port (default: 22)"
    echo "${p}--ssh-key PATH          Path to SSH private key (auto-discovered from ~/.ssh/ when omitted)"
    echo "${p}--ssh-password PASS     SSH password (prefer --ssh-password-file or DEPLOY_SSH_PASSWORD env var)"
    echo "${p}--ssh-password-file PATH  Read SSH password from file (mode 0600 required)"
    echo "${p}--ssh-known-hosts FILE  Pre-seeded known_hosts for host key verification"
    echo "${p}--ssh-host-key-check MODE  SSH host key policy: yes, no, or accept-new (default: accept-new)"
    echo "${p}--persist-known-hosts PATH  Save session known_hosts to file for reuse"
    echo "${p}--remote-timeout SECS   Remote operation timeout in seconds (default: 600)"
    echo "${p}--poll-interval SECS    Remote operation poll interval in seconds (default: 10)"
}

# --- Passthrough argument accumulation helpers ---

# Append a flag + value pair to a passthrough variable.
# Usage: VAR=$(_passthrough_add_pair "$VAR" "--flag" "$value")
_passthrough_add_pair() {
    local _var="$1" _flag="$2" _val="$3"
    printf '%s' "${_var}${_var:+
}${_flag}
${_val}"
}

# Append a flag (no value) to a passthrough variable.
# Usage: VAR=$(_passthrough_add_flag "$VAR" "--flag")
_passthrough_add_flag() {
    local _var="$1" _flag="$2"
    printf '%s' "${_var}${_var:+
}${_flag}"
}

# Check if an argument is a known SSH/remote flag.
_is_common_ssh_flag() {
    case "$1" in
        --ssh-user|--ssh-port|--ssh-key|--ssh-password|--ssh-password-file|\
        --ssh-known-hosts|--ssh-host-key-check|--persist-known-hosts|\
        --remote-timeout|--poll-interval) return 0 ;;
        *) return 1 ;;
    esac
}

# Check if an argument is a deploy node flag.
_is_deploy_node_flag() {
    case "$1" in
        --control-planes|--workers) return 0 ;;
        *) return 1 ;;
    esac
}

# Parse deploy node flags. Sets DEPLOY_CONTROL_PLANES or DEPLOY_WORKERS.
# Caller must shift $_DEPLOY_NODE_SHIFT.
_DEPLOY_NODE_SHIFT=0
_parse_deploy_node_flag() {
    _require_value "$1" "$2" "${3:-}"
    case "$2" in
        --control-planes) DEPLOY_CONTROL_PLANES="$3" ;;
        --workers)        DEPLOY_WORKERS="$3" ;;
    esac
    _DEPLOY_NODE_SHIFT=2
}

# Combined parser for deploy node flags and SSH flags.
# Usage: _parse_remote_ssh_args <argc> <arg> [next_arg]
# Returns 0 if handled (shift count in _REMOTE_SSH_SHIFT), 1 if not matched.
_REMOTE_SSH_SHIFT=0
_parse_remote_ssh_args() {
    _REMOTE_SSH_SHIFT=0
    if _is_deploy_node_flag "$2"; then
        _parse_deploy_node_flag "$@"
        _REMOTE_SSH_SHIFT=$_DEPLOY_NODE_SHIFT
        return 0
    elif _is_common_ssh_flag "$2"; then
        _parse_common_ssh_args "$@"
        _REMOTE_SSH_SHIFT=$_SSH_SHIFT
        return 0
    fi
    return 1
}

# Parse a single SSH-related option.
# Returns: 0=handled (shift count in _SSH_SHIFT), 1=not an SSH option
# Usage: _parse_common_ssh_args <argc> <arg> [next_arg]
_parse_common_ssh_args() {
    local argc=$1 arg="$2" next="${3:-}"
    _SSH_SHIFT=0
    case "$arg" in
        --ssh-user)
            _require_value "$argc" "$arg" "$next"
            DEPLOY_SSH_USER="$next"
            _SSH_SHIFT=2
            ;;
        --ssh-port)
            _require_value "$argc" "$arg" "$next"
            DEPLOY_SSH_PORT="$next"
            _SSH_SHIFT=2
            ;;
        --ssh-key)
            _require_value "$argc" "$arg" "$next"
            DEPLOY_SSH_KEY="$next"
            _SSH_SHIFT=2
            ;;
        --ssh-password)
            if [ $argc -lt 2 ]; then
                log_error "$arg requires a value"
                exit 1
            fi
            log_warn "--ssh-password exposes the password in the process list. Prefer --ssh-password-file or DEPLOY_SSH_PASSWORD env var."
            # shellcheck disable=SC2034 # used by ssh.sh
            DEPLOY_SSH_PASSWORD="$next"
            _SSH_SHIFT=2
            ;;
        --ssh-password-file)
            _require_value "$argc" "$arg" "$next"
            DEPLOY_SSH_PASSWORD_FILE="$next"
            _SSH_SHIFT=2
            ;;
        --ssh-known-hosts)
            _require_value "$argc" "$arg" "$next"
            DEPLOY_SSH_KNOWN_HOSTS_FILE="$next"
            _SSH_SHIFT=2
            ;;
        --ssh-host-key-check)
            _require_value "$argc" "$arg" "$next"
            case "$next" in
                yes|no|accept-new) ;;
                *)
                    log_error "--ssh-host-key-check must be 'yes', 'no', or 'accept-new'"
                    exit 1
                    ;;
            esac
            if [ "$next" = "no" ]; then
                log_warn "Disabling SSH host key verification allows MITM attacks. Consider 'accept-new' instead."
            fi
            # shellcheck disable=SC2034 # used by commands/deploy.sh
            DEPLOY_SSH_HOST_KEY_CHECK="$next"
            _SSH_SHIFT=2
            ;;
        --persist-known-hosts)
            _require_value "$argc" "$arg" "$next"
            # shellcheck disable=SC2034 # used by ssh.sh
            DEPLOY_PERSIST_KNOWN_HOSTS="$next"
            _SSH_SHIFT=2
            ;;
        --remote-timeout)
            _require_value "$argc" "$arg" "$next"
            if ! echo "$next" | grep -qE '^[0-9]+$' || [ "$next" -lt 1 ]; then
                log_error "--remote-timeout must be a positive integer (seconds)"
                exit 1
            fi
            # shellcheck disable=SC2034 # used by ssh.sh
            DEPLOY_REMOTE_TIMEOUT="$next"
            _SSH_SHIFT=2
            ;;
        --poll-interval)
            _require_value "$argc" "$arg" "$next"
            if ! echo "$next" | grep -qE '^[0-9]+$' || [ "$next" -lt 1 ]; then
                log_error "--poll-interval must be a positive integer (seconds)"
                exit 1
            fi
            # shellcheck disable=SC2034 # used by ssh.sh
            DEPLOY_POLL_INTERVAL="$next"
            _SSH_SHIFT=2
            ;;
        *) return 1 ;;
    esac
}

# Validate common SSH arguments (user, key, known_hosts, port)
_validate_common_ssh_args() {
    # Auto-discover SSH key if not explicitly specified
    if type _auto_discover_ssh_key >/dev/null 2>&1; then
        _auto_discover_ssh_key
    fi

    # Validate SSH user if specified
    if [ -n "$DEPLOY_SSH_USER" ] && ! echo "$DEPLOY_SSH_USER" | grep -qE '^[a-zA-Z_][a-zA-Z0-9_.-]*$'; then
        log_error "Invalid SSH user: $DEPLOY_SSH_USER"
        exit 1
    fi

    # Validate SSH key file exists if specified
    if [ -n "$DEPLOY_SSH_KEY" ] && [ ! -f "$DEPLOY_SSH_KEY" ]; then
        log_error "SSH key file not found: $DEPLOY_SSH_KEY"
        exit 1
    fi

    # Validate known_hosts file exists if specified
    if [ -n "$DEPLOY_SSH_KNOWN_HOSTS_FILE" ] && [ ! -f "$DEPLOY_SSH_KNOWN_HOSTS_FILE" ]; then
        log_error "Known hosts file not found: $DEPLOY_SSH_KNOWN_HOSTS_FILE"
        exit 1
    fi


    # Validate port number
    if ! echo "$DEPLOY_SSH_PORT" | grep -qE '^[0-9]+$' || [ "$DEPLOY_SSH_PORT" -lt 1 ] || [ "$DEPLOY_SSH_PORT" -gt 65535 ]; then
        log_error "Invalid SSH port: $DEPLOY_SSH_PORT"
        exit 1
    fi

    # Validate SSH key permissions (warning only)
    if type _validate_ssh_key_permissions >/dev/null 2>&1; then
        _validate_ssh_key_permissions
    fi

    # Load password from file if specified
    if [ -n "${DEPLOY_SSH_PASSWORD_FILE:-}" ]; then
        if type _load_ssh_password_file >/dev/null 2>&1; then
            _load_ssh_password_file "$DEPLOY_SSH_PASSWORD_FILE"
        fi
    fi
}

# Validate and normalize node lists for remote commands.
# Expects DEPLOY_CONTROL_PLANES (required), DEPLOY_WORKERS (optional) to be set.
# Usage: _validate_remote_node_args
_validate_remote_node_args() {
    DEPLOY_CONTROL_PLANES=$(_normalize_node_list "$DEPLOY_CONTROL_PLANES")
    [ -n "$DEPLOY_WORKERS" ] && DEPLOY_WORKERS=$(_normalize_node_list "$DEPLOY_WORKERS")
    if [ -z "$DEPLOY_CONTROL_PLANES" ]; then
        log_error "--control-planes contains no valid node addresses"
        exit 1
    fi
    _validate_common_ssh_args
    local all_addrs="$DEPLOY_CONTROL_PLANES"
    [ -n "$DEPLOY_WORKERS" ] && all_addrs="$all_addrs,$DEPLOY_WORKERS"
    _validate_node_addresses "$all_addrs"
}

# Normalize a comma-separated node list: trim whitespace and remove empty tokens.
# Usage: result=$(_normalize_node_list "node1 , node2,,node3")
_normalize_node_list() {
    local raw="$1" result="" token
    _old_ifs="$IFS"; IFS=','
    for token in $raw; do
        IFS="$_old_ifs"
        token="${token#"${token%%[![:space:]]*}"}"  # trim leading whitespace
        token="${token%"${token##*[![:space:]]}"}"  # trim trailing whitespace
        if [ -n "$token" ]; then
            result="${result}${result:+,}${token}"
        fi
        IFS=','
    done
    IFS="$_old_ifs"
    echo "$result"
}

# Validate node addresses (IP or hostname format, duplicate check, username validation)
# Usage: _validate_node_addresses <comma-separated-addresses>
_validate_node_addresses() {
    local all_addrs="$1"
    local _seen_hosts=""

    # Check for duplicate host addresses
    _old_ifs="$IFS"; IFS=','
    for addr in $all_addrs; do
        IFS="$_old_ifs"
        local host="${addr#*@}"
        if printf '%s\n' "$_seen_hosts" | grep -qxF "$host"; then
            log_error "Duplicate node address: $host"
            exit 1
        fi
        _seen_hosts="${_seen_hosts}${_seen_hosts:+
}${host}"
        IFS=','
    done
    IFS="$_old_ifs"

    _validate_single_node_address() {
        local addr="$1"
        case "$addr" in
            *@*)
                local username="${addr%%@*}"
                if [ -z "$username" ]; then
                    log_error "Empty username in node address: $addr"; exit 1
                fi
                case "$username" in -*)
                    log_error "Invalid username (starts with '-'): $username"; exit 1 ;;
                esac
                if ! echo "$username" | grep -qE '^[a-zA-Z0-9._-]+$'; then
                    log_error "Invalid username: $username"; exit 1
                fi ;;
        esac
        local host="${addr#*@}"
        if [ -z "$host" ]; then
            log_error "Empty node address in list"; exit 1
        fi
        case "$host" in
            '['*']')
                local ipv6_inner
                ipv6_inner="${host#\[}"; ipv6_inner="${ipv6_inner%\]}"
                if ! echo "$ipv6_inner" | grep -qE '^[a-fA-F0-9:]+$'; then
                    log_error "Invalid IPv6 address: $host"; exit 1
                fi ;;
            *:*)
                log_error "IPv6 addresses must be enclosed in brackets, e.g., [$host]"; exit 1 ;;
            *)
                if ! echo "$host" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$'; then
                    log_error "Invalid node address: $host"; exit 1
                fi ;;
        esac
    }
    _csv_for_each "$all_addrs" _validate_single_node_address
}
