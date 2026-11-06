#!/bin/sh

# Bundle module: deploy bundle generation, transfer, remote execution, and display helpers.
# Depends on lib/remote/ssh.sh for SSH transport functions (_deploy_ssh, _deploy_scp, _deploy_exec_remote, etc.).

# Module-level state for remote cleanup (must survive function scope for EXIT trap)
_DEPLOY_ALL_NODES=""
_DEPLOY_NODE_BUNDLE_DIRS=""

# --- Associative store helpers (newline-separated key=value) ---

# Store a key=value pair in the bundle dirs store
# Usage: _bundle_dir_set <host> <dir>
_bundle_dir_set() {
    _DEPLOY_NODE_BUNDLE_DIRS="${_DEPLOY_NODE_BUNDLE_DIRS}${_DEPLOY_NODE_BUNDLE_DIRS:+
}${1}=${2}"
}

# Lookup a value by key from the bundle dirs store
# Usage: _bundle_dir_lookup <host>
_bundle_dir_lookup() {
    local _lookup_key="$1" _lookup_result=""
    _lookup_result=$(printf '%s\n' "$_DEPLOY_NODE_BUNDLE_DIRS" | while IFS='=' read -r _k _v; do
        if [ "$_k" = "$_lookup_key" ]; then
            echo "$_v"
            break
        fi
    done)
    echo "$_lookup_result"
}

# --- Passthrough args helpers ---

# Append all passthrough args (newline-delimited) to a command string.
# Outputs the modified command string to stdout (caller captures via $()).
# Usage: cmd=$(_append_passthrough_to_cmd "$cmd" "$DEPLOY_PASSTHROUGH_ARGS")
_append_passthrough_to_cmd() {
    local _cmd="$1" _args_str="$2"
    if [ -n "$_args_str" ]; then
        local _pt_arg
        while IFS= read -r _pt_arg; do
            _cmd="${_cmd} $(_posix_shell_quote "$_pt_arg")"
        done <<EOF
$_args_str
EOF
    fi
    printf '%s' "$_cmd"
}

# Append passthrough args, skipping specified flags (+ their values).
# Usage: cmd=$(_append_passthrough_filtered "$cmd" "$args" "flag1 flag2 ..." ["bool_flag1 bool_flag2 ..."])
#   Third arg: space-separated flags to skip (flag + next value are both skipped)
#   Fourth arg (optional): space-separated boolean flags to skip (flag only, no value)
_append_passthrough_filtered() {
    local _cmd="$1" _args_str="$2" _skip_pairs="$3" _skip_flags="${4:-}"
    if [ -n "$_args_str" ]; then
        local _pt_arg _skip_next=false
        while IFS= read -r _pt_arg; do
            if [ "$_skip_next" = true ]; then
                _skip_next=false
                continue
            fi
            local _matched=false
            for _sf in $_skip_pairs; do
                if [ "$_pt_arg" = "$_sf" ]; then
                    _matched=true
                    _skip_next=true
                    break
                fi
            done
            if [ "$_matched" = false ]; then
                for _sf in $_skip_flags; do
                    if [ "$_pt_arg" = "$_sf" ]; then
                        _matched=true
                        break
                    fi
                done
            fi
            if [ "$_matched" = true ]; then
                continue
            fi
            _cmd="${_cmd} $(_posix_shell_quote "$_pt_arg")"
        done <<EOF
$_args_str
EOF
    fi
    printf '%s' "$_cmd"
}

# --- Bundle generation and transfer ---


# Print instructions and exit when a remote subcommand cannot transfer the
# running script (the script was read from stdin, e.g. `curl ... | sh`).
# Usage: _require_transferable_script <subcommand>
_require_transferable_script() {
    if [ "${BUNDLED_MODE:-false}" = true ] && [ -z "${_SELF_PATH:-}" ]; then
        log_error "'$1' with remote nodes must be run from a downloaded file,"
        log_error "because the script is transferred to each node:"
        log_error "  curl -fsSLO ${SETUP_K8S_RELEASE_URL}"
        log_error "  sh setup-k8s.sh $1 ..."
        exit 1
    fi
}

# Write the script to transfer to remote nodes.
# From a bundle: copy the running file. From a checkout: build a bundle.
# Usage: generate_deploy_bundle <bundle_path>
generate_deploy_bundle() {
    local bundle_path="$1"
    if [ "${BUNDLED_MODE:-false}" = true ]; then
        if [ -z "${_SELF_PATH:-}" ]; then
            log_error "Cannot locate the running script to transfer to remote nodes"
            return 1
        fi
        cp "$_SELF_PATH" "$bundle_path"
    else
        _generate_bundle_core "$bundle_path" "$SCRIPT_DIR" "${SETUP_K8S_VERSION:-dev}"
    fi
}

# Generate bundle, transfer to all nodes, and register cleanup handler.
# Expects _DEPLOY_ALL_NODES to be set (comma-separated node list).
# Sets _DEPLOY_NODE_BUNDLE_DIRS with host=dir mappings.
# Usage: _generate_and_transfer_bundle <label>
_generate_and_transfer_bundle() {
    local label="${1:-deploy}"
    local all_count
    all_count=$(_csv_count "$_DEPLOY_ALL_NODES")

    # Generate bundle
    local bundle_path
    bundle_path=$(mktemp "/tmp/setup-k8s-${label}-XXXXXX")
    chmod 600 "$bundle_path"
    generate_deploy_bundle "$bundle_path"
    log_info "Bundle generated: $(wc -c < "$bundle_path") bytes"

    # Register cleanup handler for remote temp directories
    _DEPLOY_NODE_BUNDLE_DIRS=""
    _push_cleanup _cleanup_remote_bundle_dirs

    # Transfer to all nodes
    local _i=0
    while [ "$_i" -lt "$all_count" ]; do
        local node
        node=$(_csv_get "$_DEPLOY_ALL_NODES" "$_i")
        _parse_node_address "$node"
        log_info "  [${_NODE_HOST}] Transferring bundle..."
        local rdir
        if ! rdir=$(_create_remote_tmpdir "$_NODE_USER" "$_NODE_HOST"); then
            rm -f "$bundle_path"
            return 1
        fi
        _bundle_dir_set "$_NODE_HOST" "$rdir"
        if ! _deploy_scp "$bundle_path" "$_NODE_USER" "$_NODE_HOST" "${rdir}/setup-k8s.sh"; then
            log_error "  [${_NODE_HOST}] Failed to transfer bundle"
            rm -f "$bundle_path"
            return 1
        fi
        _i=$((_i + 1))
    done
    rm -f "$bundle_path"
    log_info "Bundle transferred to all nodes"
}

# Transfer a bundle to a single node. Prints the remote bundle path to stdout.
# Usage: bundle_path=$(_transfer_bundle_to_node <user> <host> [label])
_transfer_bundle_to_node() {
    local user="$1" host="$2" label="${3:-deploy}"
    local bundle_path
    bundle_path=$(mktemp "/tmp/setup-k8s-${label}-XXXXXX")
    chmod 600 "$bundle_path"
    generate_deploy_bundle "$bundle_path"
    local rdir
    if ! rdir=$(_create_remote_tmpdir "$user" "$host"); then
        rm -f "$bundle_path"; return 1
    fi
    if ! _deploy_scp "$bundle_path" "$user" "$host" "${rdir}/setup-k8s.sh"; then
        log_error "  [${host}] Failed to transfer bundle"
        rm -f "$bundle_path"; return 1
    fi
    rm -f "$bundle_path"
    echo "${rdir}/setup-k8s.sh"
}

# Execute a command on a remote node and clean up the bundle directory afterwards.
# Usage: _run_remote_on_node <user> <host> <label> <rdir> <cmd>
_run_remote_on_node() {
    local user="$1" host="$2" label="$3" rdir="$4" cmd="$5"
    local rc=0
    _deploy_exec_remote "$user" "$host" "$label" "$cmd" || rc=1
    _deploy_ssh "$user" "$host" "rm -rf '$rdir'" >/dev/null 2>&1 || true
    return $rc
}

# Clean up remote bundle directories on all nodes.
# Uses module-level globals so EXIT trap can access them.
_cleanup_single_node_bundle() {
    _parse_node_address "$1"
    local _cdir
    _cdir=$(_bundle_dir_lookup "$_NODE_HOST")
    [ -n "$_cdir" ] && _deploy_ssh "$_NODE_USER" "$_NODE_HOST" "rm -rf '$_cdir'" >/dev/null 2>&1 || true
}
_cleanup_remote_bundle_dirs() {
    [ -z "$_DEPLOY_ALL_NODES" ] && return 0
    _csv_for_each "$_DEPLOY_ALL_NODES" _cleanup_single_node_bundle
}

# --- Node list display ---

# Log a labeled node list.
# Usage: _log_node_list <label> <csv_list>
_log_single_node() {
    _parse_node_address "$1"
    log_info "  - ${_NODE_USER}@${_NODE_HOST}"
}
_log_node_list() {
    local label="$1" csv="$2"
    local count
    count=$(_csv_count "$csv")
    log_info "${label} (${count}):"
    _csv_for_each "$csv" _log_single_node
}

# --- SSH settings display ---

# Log current SSH settings (used by dry-run displays)
_log_ssh_settings() {
    log_info "SSH Settings:"
    log_info "  Default user: $DEPLOY_SSH_USER"
    log_info "  Port: $DEPLOY_SSH_PORT"
    [ -n "$DEPLOY_SSH_KEY" ] && log_info "  Key: $DEPLOY_SSH_KEY"
    [ -n "$DEPLOY_SSH_PASSWORD" ] && log_info "  Auth: password"
    if [ -n "${DEPLOY_SSH_PASSWORD_FILE:-}" ]; then
        log_info "  Auth: password file"
    fi
}
