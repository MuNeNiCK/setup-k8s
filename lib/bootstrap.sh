#!/bin/sh

# Bootstrap: module list, module loading, exit handlers, and small POSIX
# utilities shared by every module.
#
# Execution modes:
#   - Local checkout: setup-k8s.sh sources this file and calls
#     _source_all_modules to load every module from SCRIPT_DIR.
#   - Bundle: all modules are embedded in a single script (see
#     scripts/build.sh and lib/bundle.sh); nothing is loaded at runtime.

# Minimal error logger (overridden by logging.sh when loaded)
if ! type log_error >/dev/null 2>&1; then
    log_error() { echo "ERROR: $*" >&2; }
fi

# === Module list ===

# Modules in source order, relative to the project root without ".sh".
# This is the single source of truth for both the local loader and the
# bundle builder. Distribution modules (distros/*/*.sh) follow these.
_MODULES="lib/bootstrap lib/variables lib/logging lib/detection lib/validation lib/system lib/helpers lib/cri_helpers lib/join_token lib/ssh_args lib/etcd_helpers lib/kubevip lib/ssh lib/ssh_credentials lib/ssh_session lib/bundle lib/health lib/diagnostics lib/state lib/networking lib/swap lib/completion lib/helm lib/kustomize lib/kubeadm lib/upgrade_helpers lib/upgrade_orchestration lib/runners commands/etcd_common commands/init commands/join commands/cleanup commands/deploy commands/upgrade commands/remove commands/backup commands/restore commands/renew commands/status commands/preflight"

# Print module file paths in source order.
# Usage: _module_files <project_root>
_module_files() {
    local _root="$1" _mod _f
    for _mod in $_MODULES; do
        printf '%s\n' "$_root/$_mod.sh"
    done
    for _f in "$_root"/distros/*/*.sh; do
        if [ -f "$_f" ]; then printf '%s\n' "$_f"; fi
    done
}

# Source every module except this one from SCRIPT_DIR (local checkout mode).
# Paths are built inline (not via _module_files) so that SCRIPT_DIR may
# contain spaces and definitions stay in the current shell.
_source_all_modules() {
    local _mod _f
    for _mod in $_MODULES; do
        [ "$_mod" = "lib/bootstrap" ] && continue
        if [ ! -f "$SCRIPT_DIR/$_mod.sh" ]; then
            echo "Error: Module not found: $SCRIPT_DIR/$_mod.sh" >&2
            exit 1
        fi
        # shellcheck source=/dev/null
        . "$SCRIPT_DIR/$_mod.sh"
    done
    for _f in "$SCRIPT_DIR"/distros/*/*.sh; do
        if [ -f "$_f" ]; then
            # shellcheck source=/dev/null
            . "$_f"
        fi
    done
}

# === POSIX shell utilities ===

# Shell-quote a string safely (replacement for printf '%q')
_posix_shell_quote() {
    printf "'"
    printf '%s' "$1" | sed "s/'/'\\\\''/g"
    printf "' "
}

# Count items in a comma-separated string
_csv_count() {
    [ -z "$1" ] && echo 0 && return
    _old_ifs="$IFS"; IFS=','; set -- $1; IFS="$_old_ifs"; echo $#
}

# Get the Nth item (0-indexed) from a comma-separated string
_csv_get() {
    local _idx="$2"
    _old_ifs="$IFS"; IFS=','; set -- $1; IFS="$_old_ifs"; shift "$_idx"; echo "$1"
}

# Iterate over comma-separated values, calling a callback for each trimmed item.
# Usage: _csv_for_each <csv_string> <callback>
_csv_for_each() {
    local _csv="$1" _callback="$2"
    _old_ifs="$IFS"; IFS=','
    for _item in $_csv; do
        IFS="$_old_ifs"
        _item="${_item#"${_item%%[![:space:]]*}"}"
        _item="${_item%"${_item##*[![:space:]]}"}"
        [ -z "$_item" ] && IFS=',' && continue
        "$_callback" "$_item" || { IFS="$_old_ifs"; return 1; }
        IFS=','
    done
    IFS="$_old_ifs"
}

# Check if any CSV item makes a callback return 0.
# Returns 0 on first match, 1 if no match.
# Usage: _csv_any <csv_string> <callback>
_csv_any() {
    local _csv="$1" _callback="$2"
    _old_ifs="$IFS"; IFS=','
    for _item in $_csv; do
        IFS="$_old_ifs"
        _item="${_item#"${_item%%[![:space:]]*}"}"
        _item="${_item%"${_item##*[![:space:]]}"}"
        [ -z "$_item" ] && IFS=',' && continue
        if "$_callback" "$_item"; then IFS="$_old_ifs"; return 0; fi
        IFS=','
    done
    IFS="$_old_ifs"
    return 1
}

# === Exit trap management ===
_EXIT_CLEANUP_DIRS=""
_EXIT_CLEANUP_HANDLERS=""

_append_exit_trap() {
    _EXIT_CLEANUP_DIRS="${_EXIT_CLEANUP_DIRS}${_EXIT_CLEANUP_DIRS:+
}$1"
}

_push_cleanup() {
    _EXIT_CLEANUP_HANDLERS="${_EXIT_CLEANUP_HANDLERS}${_EXIT_CLEANUP_HANDLERS:+
}$1"
}

_pop_cleanup() {
    [ -n "$_EXIT_CLEANUP_HANDLERS" ] || return 0
    _EXIT_CLEANUP_HANDLERS=$(printf '%s\n' "$_EXIT_CLEANUP_HANDLERS" | sed '$d')
}

_run_cleanup_handlers() {
    # Run handlers in reverse order (LIFO)
    if [ -n "$_EXIT_CLEANUP_HANDLERS" ]; then
        _reversed=$(printf '%s\n' "$_EXIT_CLEANUP_HANDLERS" | awk '{a[NR]=$0}END{for(i=NR;i>=1;i--)print a[i]}')
        printf '%s\n' "$_reversed" | while IFS= read -r _handler; do
            $_handler || echo "Warning: cleanup handler '$_handler' failed" >&2
        done
    fi
    # Clean up temporary directories
    if [ -n "$_EXIT_CLEANUP_DIRS" ]; then
        printf '%s\n' "$_EXIT_CLEANUP_DIRS" | while IFS= read -r dir; do
            rm -rf "$dir"
        done
    fi
}
trap _run_cleanup_handlers EXIT

# === Dispatch and entry helpers ===

# Call a dynamically-named function with a safety check
_dispatch() {
    local func_name="$1"; shift
    if type "$func_name" >/dev/null 2>&1; then
        "$func_name" "$@"
    else
        echo "Error: Required function '$func_name' not found." >&2
        return 1
    fi
}

# Require root privileges or exit.
# Usage: _require_root "command name"
_require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Error: $1 must be run as root" >&2
        exit 1
    fi
}

# Exit with dry-run output if DRY_RUN is set.
# Usage: _dry_run_guard <dry_run_fn>
_dry_run_guard() {
    if [ "$DRY_RUN" = true ]; then
        "$1"
        exit 0
    fi
}

# Detect distribution if not already detected.
_ensure_distro_detected() {
    if [ -z "${DISTRO_FAMILY:-}" ]; then detect_distribution; fi
}
