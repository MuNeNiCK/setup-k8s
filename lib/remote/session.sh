#!/bin/sh

# SSH session management, remote execution, and known_hosts.
# Credentials -> lib/remote/ssh.sh | Argument parsing -> lib/remote/args.sh | Transport -> lib/remote/ssh.sh

# Check SSH connectivity and sudo for a list of nodes
# Usage: _check_ssh_connectivity <node1> [node2] ...
_check_ssh_connectivity() {
    local ssh_failed=false
    for node in "$@"; do
        _parse_node_address "$node"
        local _ssh_err
        if _ssh_err=$(_deploy_ssh "$_NODE_USER" "$_NODE_HOST" "echo ok" 2>&1 >/dev/null); then
            log_info "  [${_NODE_HOST}] SSH OK"
            if [ "$_NODE_USER" != "root" ]; then
                local _sudo_err
                if ! _sudo_err=$(_deploy_ssh "$_NODE_USER" "$_NODE_HOST" "sudo -n true" 2>&1); then
                    log_error "  [${_NODE_HOST}] sudo -n failed — NOPASSWD sudo required for ${_NODE_USER}"
                    [ -n "$_sudo_err" ] && log_error "  [${_NODE_HOST}] ${_sudo_err}"
                    ssh_failed=true
                fi
            fi
        else
            log_error "  [${_NODE_HOST}] SSH connection failed (${_NODE_USER}@${_NODE_HOST}:${DEPLOY_SSH_PORT})"
            [ -n "$_ssh_err" ] && log_error "  [${_NODE_HOST}] ${_ssh_err}"
            ssh_failed=true
        fi
    done
    [ "$ssh_failed" = true ] && return 1
    return 0
}

# --- Shared Node Name Resolution ---

# Resolve a node's Kubernetes node name from its host IP/hostname via kubectl.
# Tries: 1) match by InternalIP address, 2) match by Hostname, 3) SSH to target and get its hostname
# Usage: _get_node_name <cp_user> <cp_host> <target_host>
# Requires: _deploy_ssh, _parse_node_address, _DEPLOY_ALL_NODES, _csv_count, _csv_get
_get_node_name() {
    local user="$1" host="$2" target_host="$3"
    local pfx; pfx=$(_sudo_prefix "$user")
    local node_name=""
    local stripped="${target_host#[}"
    stripped="${stripped%]}"

    # Try matching by InternalIP or Hostname address
    local nodes_info
    nodes_info=$(_deploy_ssh "$user" "$host" "${pfx}kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes -o jsonpath='{range .items[*]}{.metadata.name}{\" \"}{range .status.addresses[*]}{.address}{\" \"}{end}{\"\\n\"}{end}'" 2>/dev/null) || true
    if [ -n "$nodes_info" ]; then
        node_name=$(echo "$nodes_info" | while read -r name addrs; do
            for addr in $addrs; do
                if [ "$addr" = "$stripped" ] || [ "$addr" = "$target_host" ]; then
                    echo "$name"
                    return 0
                fi
            done
        done)
    fi

    # Fallback: SSH to the target node and get its hostname, then match against node names
    if [ -z "$node_name" ]; then
        _parse_node_address "$target_host"
        local target_user="$_NODE_USER" target_actual_host="$_NODE_HOST"
        # For bare IPs passed as target_host, re-parse with the original node address
        # Find the matching node from _DEPLOY_ALL_NODES
        local _all_cnt _ni
        _all_cnt=$(_csv_count "$_DEPLOY_ALL_NODES")
        _ni=0
        while [ "$_ni" -lt "$_all_cnt" ]; do
            local _node_entry
            _node_entry=$(_csv_get "$_DEPLOY_ALL_NODES" "$_ni")
            local _check_host="${_node_entry#*@}"
            if [ "$_check_host" = "$target_host" ] || [ "$_check_host" = "$stripped" ]; then
                _parse_node_address "$_node_entry"
                target_user="$_NODE_USER"
                target_actual_host="$_NODE_HOST"
                break
            fi
            _ni=$((_ni + 1))
        done
        local remote_hostname
        remote_hostname=$(_deploy_ssh "$target_user" "$target_actual_host" "hostname" 2>/dev/null | tr -d '[:space:]') || true
        if [ -n "$remote_hostname" ] && [ -n "$nodes_info" ]; then
            node_name=$(echo "$nodes_info" | while read -r name _addrs; do
                if [ "$name" = "$remote_hostname" ]; then
                    echo "$name"
                    return 0
                fi
            done)
        fi
    fi

    echo "$node_name"
}

# --- Remote temp directory ---

# Create a secure temp directory on a remote node.
# Usage: _create_remote_tmpdir <user> <host>
# Output: absolute path on stdout; returns 1 on failure.
_create_remote_tmpdir() {
    local user="$1" host="$2"
    local rdir
    rdir=$(_deploy_ssh "$user" "$host" "d=\$(mktemp -d) && chmod 700 \"\$d\" && echo \"\$d\"") || true
    rdir=$(echo "$rdir" | tr -d '[:space:]')
    if [ -z "$rdir" ]; then
        log_error "[$host] Failed to create remote temp directory"
        return 1
    fi
    case "$rdir" in
        /*) ;;
        *)
            log_error "[$host] Failed to create remote temp directory (got: '${rdir}')"
            return 1
            ;;
    esac
    echo "$rdir"
}

# --- Remote Execution ---

# Execute a command on a remote node via nohup + polling
# Usage: _deploy_exec_remote <user> <host> <description> <command>
_deploy_exec_remote() {
    local user="$1" host="$2" desc="$3" cmd="$4"

    log_info "[$host] Starting: $desc"

    local remote_dir
    if ! remote_dir=$(_create_remote_tmpdir "$user" "$host"); then
        return 1
    fi

    local remote_script="${remote_dir}/run.sh"
    local log_file="${remote_dir}/run.log"
    local exit_file="${remote_dir}/run.exit"

    # Write command to remote script via stdin
    if ! printf '%s\n' "$cmd" | _deploy_ssh "$user" "$host" "cat > '$remote_script' && chmod 700 '$remote_script'"; then
        log_error "[$host] Failed to upload remote script"
        _deploy_ssh "$user" "$host" "rm -rf '$remote_dir'" >/dev/null 2>&1 || true
        return 1
    fi

    # Launch via nohup (nohup wraps the entire command to ensure exit-code file is written)
    if ! _deploy_ssh "$user" "$host" "nohup sh -c 'sh \"$remote_script\" > \"$log_file\" 2>&1; echo \$? > \"$exit_file\"' </dev/null >/dev/null 2>&1 &"; then
        log_error "[$host] Failed to launch remote command"
        _deploy_ssh "$user" "$host" "rm -rf '$remote_dir'" >/dev/null 2>&1 || true
        return 1
    fi

    # Poll for completion
    local elapsed=0 _last_poll_err=""
    while [ "$elapsed" -lt "$DEPLOY_REMOTE_TIMEOUT" ]; do
        sleep "$DEPLOY_POLL_INTERVAL"
        elapsed=$((elapsed + DEPLOY_POLL_INTERVAL))

        if _last_poll_err=$(_deploy_ssh "$user" "$host" "test -f '$exit_file'" 2>&1 >/dev/null); then
            break
        fi

        # Show progress
        local progress_line
        progress_line=$(_deploy_ssh "$user" "$host" "tail -1 '$log_file'" 2>/dev/null || true)
        if [ -n "$progress_line" ]; then
            log_info "[$host] [${elapsed}s] $progress_line"
        fi
    done

    if [ "$elapsed" -ge "$DEPLOY_REMOTE_TIMEOUT" ]; then
        log_error "[$host] Timeout after ${DEPLOY_REMOTE_TIMEOUT}s: $desc"
        [ -n "$_last_poll_err" ] && log_error "[$host] Last poll error: $_last_poll_err"
        log_error "[$host] Remote log:"
        _deploy_ssh "$user" "$host" "cat '$log_file'" || true
        _deploy_ssh "$user" "$host" "rm -rf '$remote_dir'" >/dev/null 2>&1 || true
        return 1
    fi

    # Retrieve exit code
    local remote_exit
    remote_exit=$(_deploy_ssh "$user" "$host" "cat '$exit_file'" || echo "1")
    remote_exit=$(echo "$remote_exit" | tr -d '[:space:]')

    if ! echo "$remote_exit" | grep -qE '^[0-9]+$'; then
        log_error "[$host] Invalid exit code from remote: '$remote_exit'"
        _deploy_ssh "$user" "$host" "rm -rf '$remote_dir'" >/dev/null 2>&1 || true
        return 1
    fi

    if [ "$remote_exit" -ne 0 ]; then
        log_error "[$host] Failed (exit $remote_exit): $desc"
        log_error "[$host] Remote log:"
        _deploy_ssh "$user" "$host" "cat '$log_file'" || true
        _deploy_ssh "$user" "$host" "rm -rf '$remote_dir'" >/dev/null 2>&1 || true
        return 1
    fi

    # Clean up remote temp directory
    _deploy_ssh "$user" "$host" "rm -rf '$remote_dir'" >/dev/null 2>&1 || true

    log_info "[$host] Completed: $desc"
    return 0
}

# --- Remote session initialization ---

# Standard initialization for remote-mode commands.
# Sets _DEPLOY_ALL_NODES, checks SSH connectivity.
# Usage: _init_remote_session <label> <nodes_csv>
_init_remote_session() {
    local label="$1"
    _DEPLOY_ALL_NODES="$2"
    _log_ssh_host_key_policy
    _setup_session_known_hosts "$label"
    if ! _check_all_nodes_connectivity; then
        log_error "SSH connectivity check failed. Aborting."
        return 1
    fi
}

# --- Session-scoped known_hosts management ---

# Log SSH host key policy for user awareness.
# Usage: _log_ssh_host_key_policy
_log_ssh_host_key_policy() {
    if [ "${DEPLOY_SSH_HOST_KEY_CHECK}" = "accept-new" ]; then
        log_info "SSH host key check: accept-new (TOFU)."
    elif [ "${DEPLOY_SSH_HOST_KEY_CHECK}" = "yes" ] && [ -z "$DEPLOY_SSH_KNOWN_HOSTS_FILE" ]; then
        log_info "SSH strict host key checking is enabled."
        log_info "Provide known_hosts with --ssh-known-hosts to proceed:"
        log_info "  ssh-keyscan -H <node-ip> >> known_hosts"
    fi
}

# Check SSH connectivity to all nodes in _DEPLOY_ALL_NODES (CSV).
# Usage: _check_all_nodes_connectivity
_CONN_NODES=""
_collect_conn_node() { _CONN_NODES="${_CONN_NODES} $1"; }
_check_all_nodes_connectivity() {
    _CONN_NODES=""
    _csv_for_each "$_DEPLOY_ALL_NODES" _collect_conn_node
    # shellcheck disable=SC2086 # intentional word splitting
    _check_ssh_connectivity $_CONN_NODES
}

# Create a session-scoped known_hosts file, optionally seeded from a user-provided file.
# Registers a cleanup handler to remove it on exit.
# Usage: _setup_session_known_hosts <label>
_setup_session_known_hosts() {
    local label="${1:-session}"
    _DEPLOY_KNOWN_HOSTS=$(mktemp "/tmp/${label}-known-hosts-XXXXXX")
    chmod 600 "$_DEPLOY_KNOWN_HOSTS"
    if [ -n "$DEPLOY_SSH_KNOWN_HOSTS_FILE" ] && [ -f "$DEPLOY_SSH_KNOWN_HOSTS_FILE" ]; then
        cp "$DEPLOY_SSH_KNOWN_HOSTS_FILE" "$_DEPLOY_KNOWN_HOSTS"
    fi
    if [ -n "$DEPLOY_SSH_PASSWORD" ]; then
        _setup_ssh_askpass
    fi
    _push_cleanup _teardown_session_known_hosts
}

# Clean up session-scoped known_hosts file and askpass script.
# Persists to DEPLOY_PERSIST_KNOWN_HOSTS path if set.
# Usage: _teardown_session_known_hosts
_teardown_session_known_hosts() {
    if [ -n "${DEPLOY_PERSIST_KNOWN_HOSTS:-}" ] && [ -n "$_DEPLOY_KNOWN_HOSTS" ] && [ -f "$_DEPLOY_KNOWN_HOSTS" ]; then
        _persist_known_hosts "$DEPLOY_PERSIST_KNOWN_HOSTS"
    fi
    rm -f "$_DEPLOY_KNOWN_HOSTS"
    _DEPLOY_KNOWN_HOSTS=""
    _teardown_ssh_askpass
}

# --- known_hosts persistence ---

# Persist session known_hosts to a user-specified path for reuse.
# Usage: _persist_known_hosts <dest_path>
_persist_known_hosts() {
    local dest="$1"
    if [ -z "$_DEPLOY_KNOWN_HOSTS" ] || [ ! -f "$_DEPLOY_KNOWN_HOSTS" ]; then
        log_warn "No session known_hosts to persist"
        return 0
    fi
    cp "$_DEPLOY_KNOWN_HOSTS" "$dest"
    chmod 600 "$dest"
    log_info "Session known_hosts persisted to: $dest"
}
