#!/bin/sh

# SSH transport: low-level SSH/SCP operations and node address parsing.
# Argument parsing -> lib/remote/args.sh | Session management -> lib/remote/session.sh

# --- SSH Transport ---

# Session-scoped known_hosts file (set by _setup_session_known_hosts)
_DEPLOY_KNOWN_HOSTS=""

# --- SSH_ASKPASS infrastructure ---

_DEPLOY_ASKPASS_SCRIPT=""

# Create a temporary SSH_ASKPASS script that echoes the password.
# Called once during SSH session setup; cleaned up by _teardown_ssh_askpass.
_setup_ssh_askpass() {
    [ -n "$_DEPLOY_ASKPASS_SCRIPT" ] && return 0
    _DEPLOY_ASKPASS_SCRIPT=$(mktemp /tmp/.setup-k8s-askpass-XXXXXX)
    cat > "$_DEPLOY_ASKPASS_SCRIPT" <<'ASKPASS_EOF'
#!/bin/sh
echo "$DEPLOY_SSH_PASSWORD"
ASKPASS_EOF
    chmod 700 "$_DEPLOY_ASKPASS_SCRIPT"
}

_teardown_ssh_askpass() {
    [ -n "$_DEPLOY_ASKPASS_SCRIPT" ] && rm -f "$_DEPLOY_ASKPASS_SCRIPT"
    _DEPLOY_ASKPASS_SCRIPT=""
}

# Run a command with SSH_ASKPASS enabled for password authentication.
# Usage: _with_askpass <command...>
_with_askpass() {
    SSH_ASKPASS="$_DEPLOY_ASKPASS_SCRIPT" SSH_ASKPASS_REQUIRE=force DEPLOY_SSH_PASSWORD="$DEPLOY_SSH_PASSWORD" setsid -w "$@"
}

# --- SSH Infrastructure ---

# Build SSH options string (space-separated, no arrays)
# Sets: _SSH_OPTS (global string)
# Usage: _build_deploy_ssh_opts [host]  (per-node port/key from --config)
_build_deploy_ssh_opts() {
    local known_hosts="${_DEPLOY_KNOWN_HOSTS:-/dev/null}"
    local port key
    port=$(node_override "${1:-}" port); port="${port:-$DEPLOY_SSH_PORT}"
    key=$(node_override "${1:-}" key); key="${key:-$DEPLOY_SSH_KEY}"
    local host_key_policy="${DEPLOY_SSH_HOST_KEY_CHECK:-yes}"
    _SSH_OPTS="-o StrictHostKeyChecking=$host_key_policy -o UserKnownHostsFile=$known_hosts -o LogLevel=ERROR -o ConnectTimeout=10"
    # Prevent interactive prompts in automated mode (BatchMode not used with password auth)
    if [ -z "$DEPLOY_SSH_PASSWORD" ]; then
        # If SSH agent is available and no explicit key/password, skip BatchMode
        # to allow agent-based auth that may prompt for key passphrase
        if [ -z "${SSH_AUTH_SOCK:-}" ] || [ -n "$key" ]; then
            _SSH_OPTS="$_SSH_OPTS -o BatchMode=yes"
        fi
    fi
    _SSH_OPTS="$_SSH_OPTS -p $port"
    if [ -n "$key" ]; then
        _SSH_OPTS="$_SSH_OPTS -i $key"
    fi
}

# Run SSH command on a remote node
# Usage: _deploy_ssh <user> <host> <command...>
_deploy_ssh() {
    local user="$1" host="$2"; shift 2
    _build_deploy_ssh_opts "$host"

    # Strip brackets from IPv6 addresses for SSH (SSH needs user@::1, not user@[::1])
    local ssh_host="$host"
    case "$host" in
        '['*']')
            ssh_host="${host#\[}"
            ssh_host="${ssh_host%\]}"
            ;;
    esac

    if [ -n "$DEPLOY_SSH_PASSWORD" ]; then
        # shellcheck disable=SC2086 # intentional word splitting on SSH opts
        _with_askpass ssh $_SSH_OPTS -- "${user}@${ssh_host}" "$@"
    else
        # shellcheck disable=SC2086 # intentional word splitting on SSH opts
        ssh $_SSH_OPTS -- "${user}@${ssh_host}" "$@"
    fi
}

# Build SCP options string and bracketed host from SSH opts.
# Sets: _SCP_OPTS (string), _SCP_HOST (string)
_build_scp_args() {
    local host="$1"
    _build_deploy_ssh_opts "$host"

    # Convert -p to -P for scp
    _SCP_OPTS=$(echo "$_SSH_OPTS" | sed "s/ -p / -P /")

    _SCP_HOST="$host"
    case "$host" in
        *:*)
            case "$host" in
                '['*']') ;;  # already bracketed
                *) _SCP_HOST="[$host]" ;;
            esac
            ;;
    esac
}

# Run scp with optional password auth
_run_scp() {
    if [ -n "$DEPLOY_SSH_PASSWORD" ]; then
        _with_askpass scp "$@"
    else
        scp "$@"
    fi
}

# SCP file to a remote node
# Usage: _deploy_scp <local_path> <user> <host> <remote_path>
_deploy_scp() {
    local local_path="$1" user="$2" host="$3" remote_path="$4"
    _build_scp_args "$host"
    # shellcheck disable=SC2086 # intentional word splitting on SCP opts
    _run_scp $_SCP_OPTS "$local_path" "${user}@${_SCP_HOST}:${remote_path}"
}

# SCP file from a remote node to local
# Usage: _deploy_scp_from <user> <host> <remote_path> <local_path>
_deploy_scp_from() {
    local user="$1" host="$2" remote_path="$3" local_path="$4"
    _build_scp_args "$host"
    # shellcheck disable=SC2086 # intentional word splitting on SCP opts
    _run_scp $_SCP_OPTS "${user}@${_SCP_HOST}:${remote_path}" "$local_path"
}

# --- Node address parsing ---

# Parse node address: "user@ip" or "ip" -> sets _NODE_USER, _NODE_HOST
_parse_node_address() {
    local addr="$1"
    case "$addr" in
        *@*)
            _NODE_USER="${addr%%@*}"
            _NODE_HOST="${addr#*@}"
            ;;
        *)
            _NODE_USER="$DEPLOY_SSH_USER"
            _NODE_HOST="$addr"
            ;;
    esac
}

# ============================================================
# SSH credentials (key discovery, password file)
# ============================================================

# SSH credential management: key validation, auto-discovery, password file.
# Session management -> lib/remote/session.sh | Transport -> lib/remote/ssh.sh

# --- SSH key permission validation ---

# Validate SSH key file permissions (warn if too permissive)
_validate_ssh_key_permissions() {
    if [ -z "$DEPLOY_SSH_KEY" ] || [ ! -f "$DEPLOY_SSH_KEY" ]; then
        return 0
    fi
    local perms
    perms=$(stat -c '%a' "$DEPLOY_SSH_KEY" 2>/dev/null || stat -f '%Lp' "$DEPLOY_SSH_KEY" 2>/dev/null) || return 0
    case "$perms" in
        600|400) ;;
        *)
            log_warn "SSH key '$DEPLOY_SSH_KEY' has permissions $perms (recommend 600 or 400)"
            ;;
    esac
}

# --- SSH key auto-discovery ---

# Auto-discover SSH private key from the invoking user's ~/.ssh/ directory.
# Searches: id_ed25519, id_rsa, id_ecdsa (in order of preference).
# Only sets DEPLOY_SSH_KEY if not already specified and a key file is found.
_auto_discover_ssh_key() {
    # Skip if already explicitly set
    [ -n "$DEPLOY_SSH_KEY" ] && return 0

    # Determine the home directory of the original (pre-sudo) user
    local ssh_home=""
    if [ -n "${SUDO_USER:-}" ]; then
        ssh_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)" || true
        [ -z "$ssh_home" ] && ssh_home="/home/$SUDO_USER"
    else
        ssh_home="${HOME:-}"
    fi
    [ -z "$ssh_home" ] && return 0

    local key_name
    for key_name in id_ed25519 id_rsa id_ecdsa; do
        if [ -f "${ssh_home}/.ssh/${key_name}" ]; then
            DEPLOY_SSH_KEY="${ssh_home}/.ssh/${key_name}"
            log_info "SSH key auto-discovered: $DEPLOY_SSH_KEY"
            return 0
        fi
    done
}

# --- SSH password file support ---

# Load SSH password from a file (validates permissions).
# Usage: _load_ssh_password_file <path>
_load_ssh_password_file() {
    local path="$1"
    if [ ! -f "$path" ]; then
        log_error "SSH password file not found: $path"
        return 1
    fi
    local perms
    perms=$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null) || true
    case "$perms" in
        600|400) ;;
        *)
            log_error "SSH password file '$path' has permissions $perms (must be 600 or 400)"
            return 1
            ;;
    esac
    DEPLOY_SSH_PASSWORD=$(cat "$path")
    if [ -z "$DEPLOY_SSH_PASSWORD" ]; then
        log_error "SSH password file '$path' is empty"
        return 1
    fi
}

# === Remote command helpers ===

# Build sudo prefix for non-root remote execution.
# Usage: local pfx; pfx=$(_sudo_prefix "$user")
_sudo_prefix() {
    if [ "$1" != "root" ]; then
        printf 'sudo -n '
    fi
}
