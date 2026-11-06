#!/bin/sh

# Remote execution interface for subcommands that operate on nodes over SSH.
#
#   remote_session_open [--no-transfer] <label> <nodes_csv>
#       Check SSH (and NOPASSWD sudo) on every node, transfer the running
#       script to each node (unless --no-transfer), and register cleanup for
#       an abnormal exit.
#   remote_node_dir <node>
#       Print the per-node working directory that holds the transferred script.
#   remote_run [--env NAME=VALUE]... [--forward ARGS] [--drop "FLAG..."] \
#              <node> <description> <subcommand> [args...]
#       Run "setup-k8s.sh <subcommand> [args...]" on <node> as root (sudo -n
#       for non-root users) and wait for it. --forward appends the
#       newline-separated ARGS (as collected by _passthrough_add_*); flags in
#       --drop are removed from them together with their values.
#   remote_exec <node> <command>
#       Run a shell command on <node> as root and print its output.
#   remote_session_close
#       Remove the transferred scripts and the session known_hosts file.
#
# <node> is "user@host" or "host" (the default SSH user applies).

_REMOTE_SESSION_OPEN=false

remote_session_open() {
    local transfer=true
    if [ "$1" = "--no-transfer" ]; then
        transfer=false
        shift
    fi
    local label="$1" nodes="$2"
    if ! _init_remote_session "$label" "$nodes"; then
        _teardown_session_known_hosts
        _pop_cleanup
        return 1
    fi
    _REMOTE_SESSION_OPEN=true
    [ "$transfer" = true ] || return 0
    log_info "Transferring setup-k8s.sh to all nodes..."
    if ! _generate_and_transfer_bundle "$label"; then
        remote_session_close
        return 1
    fi
}

remote_session_close() {
    [ "$_REMOTE_SESSION_OPEN" = true ] || return 0
    if [ -n "$_DEPLOY_NODE_BUNDLE_DIRS" ]; then
        _cleanup_remote_bundle_dirs
        _DEPLOY_NODE_BUNDLE_DIRS=""
        _pop_cleanup
    fi
    _teardown_session_known_hosts
    _pop_cleanup
    _REMOTE_SESSION_OPEN=false
}

remote_node_dir() {
    _parse_node_address "$1"
    _bundle_dir_lookup "$_NODE_HOST"
}

remote_exec() {
    _parse_node_address "$1"
    _deploy_ssh "$_NODE_USER" "$_NODE_HOST" "$(_sudo_prefix "$_NODE_USER")$2"
}

# Boolean flags that never take a value.
_REMOTE_BOOLEAN_FLAGS="--skip-drain --no-rollback --auto-step-upgrade --swap-enabled --ha --control-plane --first-control-plane --check-only --force --preserve-cni"

# Print the forwarded arguments (newline-separated) without the dropped
# flags, shell-quoted on one line. Dropped flags that take a value are
# removed together with their value.
_remote_forward_filtered() {
    local args="$1" drop="$2" arg flag skip_next=false matched is_bool out=""
    [ -n "$args" ] || return 0
    while IFS= read -r arg; do
        if [ "$skip_next" = true ]; then
            skip_next=false
            continue
        fi
        matched=false
        for flag in $drop; do
            if [ "$arg" = "$flag" ]; then matched=true; break; fi
        done
        if [ "$matched" = true ]; then
            is_bool=false
            for flag in $_REMOTE_BOOLEAN_FLAGS; do
                if [ "$arg" = "$flag" ]; then is_bool=true; break; fi
            done
            if [ "$is_bool" = false ]; then skip_next=true; fi
            continue
        fi
        out="${out}$(_posix_shell_quote "$arg")"
    done <<EOF
$args
EOF
    printf '%s' "$out"
}

remote_run() {
    local env_prefix="" forward="" drop=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --env)     env_prefix="${env_prefix}$(_posix_shell_quote "$2")"; shift 2 ;;
            --forward) forward="$2"; shift 2 ;;
            --drop)    drop="$2"; shift 2 ;;
            *) break ;;
        esac
    done
    local node="$1" desc="$2" subcmd="$3"
    shift 3

    _parse_node_address "$node"
    local user="$_NODE_USER" host="$_NODE_HOST" dir
    dir=$(_bundle_dir_lookup "$host")
    if [ -z "$dir" ]; then
        log_error "[$host] setup-k8s.sh was not transferred (remote_session_open not called for this node)"
        return 1
    fi

    local cmd arg
    cmd="$(_sudo_prefix "$user")"
    [ -n "$env_prefix" ] && cmd="${cmd}env ${env_prefix}"
    cmd="${cmd}sh $(_posix_shell_quote "${dir}/setup-k8s.sh")$(_posix_shell_quote "$subcmd")"
    for arg in "$@"; do
        cmd="${cmd}$(_posix_shell_quote "$arg")"
    done
    cmd="${cmd}$(_remote_forward_filtered "$forward" "$drop")"

    _deploy_exec_remote "$user" "$host" "$desc" "$cmd"
}
