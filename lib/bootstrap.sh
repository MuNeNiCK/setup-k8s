#!/bin/sh

# Shared bootstrap logic for setup-k8s.sh
# Provides: exit trap management, module validation, _dispatch
#
# === Sections ===
# 1. Minimal logger
# 2. Module lists
# 3. POSIX shell utilities
# 4. Exit trap management
# 5. Module validation
# 6. Download helpers
# 7. Dynamic dispatch
# 8. Module loaders
# 9. Entry helpers

# === Section 1: Minimal logger ===

# Minimal error logger (overridden by logging.sh when loaded)
if ! type log_error >/dev/null 2>&1; then
    log_error() { echo "ERROR: $*" >&2; }
fi

# === Section 2: Module lists ===

# Canonical module lists (single source of truth).
# Used by per-subcommand module sets, bundle generation, and distro detection.
# bootstrap is listed for bundling but excluded from runtime loading (already sourced).
_LIB_MODULES="variables logging detection validation system helpers cri_helpers join_token ssh_args etcd_helpers kubevip ssh ssh_credentials ssh_session bundle health diagnostics state networking swap completion helm kustomize kubeadm upgrade_helpers upgrade_orchestration runners"
_COMMAND_MODULES="etcd_common init join cleanup deploy upgrade remove backup restore renew status preflight"
# Combined list for bundle generation (BUNDLE_COMMON_MODULES in variables.sh)
_COMMON_MODULES="$_LIB_MODULES $_COMMAND_MODULES"
_DISTRO_FAMILIES="alpine arch debian generic rhel suse"
_DISTRO_MODULES="cleanup containerd crio dependencies kubernetes"

# Per-subcommand module sets for selective loading (curl|sh and local mode)
_SETUP_CMD_MODULES="init join cleanup"
_SETUP_LIB_MODULES="variables logging detection validation system helpers cri_helpers join_token kubevip networking swap completion helm kustomize kubeadm"
_CLEANUP_CMD_MODULES="cleanup"
_CLEANUP_LIB_MODULES="variables logging detection validation system helpers networking swap completion helm kustomize"
_UPGRADE_LOCAL_CMD_MODULES="upgrade"
_UPGRADE_LOCAL_LIB_MODULES="variables logging detection validation system helpers upgrade_helpers bundle"
_ETCD_LOCAL_CMD_MODULES="etcd_common backup restore"
_ETCD_LOCAL_LIB_MODULES="variables logging detection validation system helpers etcd_helpers"

# === Section 3: POSIX shell utilities ===

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

# === Section 4: Exit trap management ===
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

# === Section 5: Module validation ===

# Validate that a downloaded module looks like a shell script
# Usage: _validate_shell_module <file>
_validate_shell_module() {
    local file="$1"
    if [ ! -s "$file" ]; then
        echo "Error: Module file '$file' is empty or missing" >&2
        return 1
    fi
    local first_char
    first_char=$(head -c1 "$file")
    if [ "$first_char" != "#" ]; then
        echo "Error: Module file '$file' does not appear to be a valid shell script" >&2
        return 1
    fi
    local _syntax_err
    if ! _syntax_err=$(sh -n "$file" 2>&1); then
        echo "Error: Module file '$file' contains syntax errors:" >&2
        echo "$_syntax_err" >&2
        return 1
    fi
    return 0
}

# === Section 6: Download helpers ===

# Single URL download with unified curl flags.
# Usage: _curl_download <url> <output> [quiet]
_curl_download() {
    local _url="$1" _output="$2" _quiet="${3:-}"
    if [ "$_quiet" = "quiet" ]; then
        curl -fsSL --retry 3 --retry-delay 2 "$_url" > "$_output" 2>/dev/null
    else
        curl -fsSL --retry 3 --retry-delay 2 "$_url" > "$_output"
    fi
}

# Download a module and validate it as a shell script.
# Usage: _download_and_validate_module <url> <output> <label>
_download_and_validate_module() {
    local _url="$1" _output="$2" _label="$3"
    if ! _curl_download "$_url" "$_output"; then
        echo "Error: Failed to download ${_label}" >&2
        return 1
    fi
    _validate_shell_module "$_output" || return 1
}

# Download a module with lib/ → commands/ fallback.
# Usage: _download_module_with_fallback <mod_name> <output> <prefix1> [prefix2 ...]
_download_module_with_fallback() {
    local _mod_name="$1" _output="$2"; shift 2
    local _prefix
    for _prefix in "$@"; do
        if _curl_download "${GITHUB_BASE_URL}/${_prefix}/${_mod_name}.sh" "$_output" "quiet" && [ -s "$_output" ]; then
            _validate_shell_module "$_output" || return 1
            return 0
        fi
    done
    echo "Error: Failed to download ${_mod_name}.sh from ${*}" >&2
    return 1
}

# === Section 7: Dynamic dispatch ===

# Helper to call dynamically-named functions with safety check
_dispatch() {
    local func_name="$1"; shift
    if type "$func_name" >/dev/null 2>&1; then
        "$func_name" "$@"
    else
        echo "Error: Required function '$func_name' not found." >&2
        return 1
    fi
}

# === Section 8: Module loaders ===

# Load a set of modules from lib/ or commands/.
# Usage: _load_module_set "mod1 mod2 mod3"
_load_module_set() {
    for _mod in $1; do
        if [ -f "$SCRIPT_DIR/lib/${_mod}.sh" ]; then
            . "$SCRIPT_DIR/lib/${_mod}.sh"
        elif [ -f "$SCRIPT_DIR/commands/${_mod}.sh" ]; then
            . "$SCRIPT_DIR/commands/${_mod}.sh"
        else
            echo "Error: Module ${_mod}.sh not found in lib/ or commands/" >&2
            exit 1
        fi
    done
}

# Load modules for a subcommand in any execution mode (bundled, local, standalone).
# In bundled mode: modules are already embedded, no action needed.
# In local mode: sources from SCRIPT_DIR/lib/ and commands/.
# In standalone/curl|sh mode: downloads from GitHub.
# Usage: _load_local_modules <prefix> <modules>
_load_local_modules() {
    local _prefix="$1" _modules="$2"
    if { [ "$_STDIN_MODE" = false ] && [ -d "$SCRIPT_DIR/lib" ]; } || [ "$BUNDLED_MODE" = "true" ]; then
        if [ "$BUNDLED_MODE" != "true" ]; then
            _load_module_set "$_modules"
        fi
    else
        _load_modules_standalone "$_prefix" $_modules
    fi
}

# === Section 9: Entry helpers ===

# Show help if --help/-h is present in args.
# Usage: _show_help_if_requested <help_fn> "$@"
_show_help_if_requested() {
    _shfn="$1"; shift
    for _arg in "$@"; do
        if [ "$_arg" = "--help" ] || [ "$_arg" = "-h" ]; then
            . "$SCRIPT_DIR/lib/variables.sh" 2>/dev/null || true
            . "$SCRIPT_DIR/lib/logging.sh" 2>/dev/null || true
            . "$SCRIPT_DIR/lib/validation.sh" 2>/dev/null || true
            . "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null || true
            . "$SCRIPT_DIR/lib/etcd_helpers.sh" 2>/dev/null || true
            . "$SCRIPT_DIR/lib/ssh_args.sh" 2>/dev/null || true
            . "$SCRIPT_DIR/lib/ssh.sh" 2>/dev/null || true
            . "$SCRIPT_DIR/lib/ssh_credentials.sh" 2>/dev/null || true
            . "$SCRIPT_DIR/lib/ssh_session.sh" 2>/dev/null || true
            # Source command modules (help functions live in commands/)
            for _cmd_sh in "$SCRIPT_DIR"/commands/*.sh; do
                [ -f "$_cmd_sh" ] && . "$_cmd_sh"
            done
            "$_shfn"
        fi
    done
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
# Usage: _ensure_distro_detected
_ensure_distro_detected() {
    if [ -z "${DISTRO_FAMILY:-}" ]; then detect_distribution; fi
}

# Download and source modules in standalone/curl|sh mode.
# Tries lib/ first, then commands/ for each module.
# Usage: _load_modules_standalone <prefix> <mod1> [mod2 ...]
_load_modules_standalone() {
    local _prefix="$1"; shift
    local _modules="$*"
    local _tmp_dir
    _tmp_dir=$(mktemp -d "/tmp/setup-k8s-${_prefix}-XXXXXX")
    _append_exit_trap "$_tmp_dir"
    for _mod in $_modules; do
        if ! _download_module_with_fallback "$_mod" "$_tmp_dir/${_mod}.sh" lib commands; then
            exit 1
        fi
        . "$_tmp_dir/${_mod}.sh"
    done
}

# Download and source a single extra module in standalone/curl|sh mode.
# Tries lib/ first, then commands/.
# Usage: _load_extra_module_standalone <module_name>
_load_extra_module_standalone() {
    local _mod="$1"
    local _tmp
    _tmp=$(mktemp "/tmp/${_mod}-XXXXXX")
    if ! _download_module_with_fallback "$_mod" "$_tmp" lib commands; then
        rm -f "$_tmp"
        exit 1
    fi
    . "$_tmp"
    rm -f "$_tmp"
}

# Parameterized module loader for online mode (curl | sh).
# Usage: load_modules <temp_prefix> <cmd_modules> <lib_modules> [<distro_module> ...]
#   temp_prefix:     prefix for the temp directory name (e.g. "setup-k8s")
#   cmd_modules:     space-separated list of command modules to download
#   lib_modules:     space-separated list of lib modules to download
#   distro_modules:  list of distro-specific module names to download (e.g. "dependencies containerd crio kubernetes cleanup")
load_modules() {
    local temp_prefix="$1"
    local cmd_modules="$2"
    local lib_modules="$3"
    shift 3
    local distro_modules="$*"

    # Ensure detection prerequisites are always present
    for _req in variables logging detection; do
        case " $lib_modules " in
            *" $_req "*) ;;
            *) lib_modules="$_req $lib_modules" ;;
        esac
    done

    echo "Loading modules from GitHub..." >&2

    local temp_dir
    temp_dir=$(mktemp -d "/tmp/${temp_prefix}-XXXXXX")
    _append_exit_trap "$temp_dir"

    echo "Downloading command modules..." >&2
    for module in $cmd_modules; do
        echo "  - Downloading commands/${module}.sh" >&2
        _download_and_validate_module "${GITHUB_BASE_URL}/commands/${module}.sh" "$temp_dir/${module}.sh" "commands/${module}.sh" || return 1
    done
    echo "Downloading lib modules..." >&2
    for module in $lib_modules; do
        echo "  - Downloading lib/${module}.sh" >&2
        _download_and_validate_module "${GITHUB_BASE_URL}/lib/${module}.sh" "$temp_dir/${module}.sh" "lib/${module}.sh" || return 1
    done

    for module in variables logging detection; do
        . "$temp_dir/${module}.sh"
    done

    detect_distribution
    local distro_family_local="$DISTRO_FAMILY"

    log_info "Downloading modules for $distro_family_local..."
    for module in $distro_modules; do
        log_info "  - Downloading distros/$distro_family_local/${module}.sh"
        _download_and_validate_module "${GITHUB_BASE_URL}/distros/$distro_family_local/${module}.sh" "$temp_dir/${distro_family_local}_${module}.sh" "distros/$distro_family_local/${module}.sh" || return 1
    done

    # Download arch-specific AUR module
    if [ "$distro_family_local" = "arch" ]; then
        log_info "  - Downloading distros/arch/aur.sh"
        _download_and_validate_module "${GITHUB_BASE_URL}/distros/arch/aur.sh" "$temp_dir/arch_aur.sh" "distros/arch/aur.sh" || return 1
    fi

    log_info "Loading all modules..."
    # Skip modules already sourced for distro detection (variables, logging, detection)
    local _already_sourced=" variables logging detection "
    for module in $lib_modules $cmd_modules; do
        case "$_already_sourced" in
            *" $module "*) continue ;;
        esac
        . "$temp_dir/${module}.sh"
    done
    for module in $distro_modules; do
        . "$temp_dir/${distro_family_local}_${module}.sh"
    done
    if [ "$distro_family_local" = "arch" ] && [ -f "$temp_dir/arch_aur.sh" ]; then
        . "$temp_dir/arch_aur.sh"
    fi

    log_info "All modules loaded successfully"
    return 0
}

# Parameterized local runner. Verifies key function exists; if not, sources from SCRIPT_DIR.
# Usage: run_local <key_function> <modules> [<distro_module> ...]
#   key_function:   function name to check (e.g. "parse_setup_args" or "parse_cleanup_args")
#   modules:        space-separated list of lib+command modules to source
#   distro_modules: specific distro modules to load (e.g. "dependencies containerd crio kubernetes")
run_local() {
    local key_function="$1"
    local modules="$2"
    shift 2
    local distro_modules="$*"

    if type "$key_function" >/dev/null 2>&1; then
        return 0
    fi

    if [ "$_STDIN_MODE" = true ]; then
        echo "Error: Bundled mode via stdin requires embedded modules. Cannot safely source local files." >&2
        return 1
    fi
    echo "Local mode: functions not bundled, loading from $SCRIPT_DIR..." >&2
    _load_module_set "$modules"
    detect_distribution
    for module in $distro_modules; do
        if [ -f "$SCRIPT_DIR/distros/$DISTRO_FAMILY/${module}.sh" ]; then
            . "$SCRIPT_DIR/distros/$DISTRO_FAMILY/${module}.sh"
        else
            echo "Error: Required module not found: distros/$DISTRO_FAMILY/${module}.sh" >&2
            return 1
        fi
    done
    return 0
}

# Download all project modules to a temporary directory (for deploy in curl|sh mode).
# Creates the same directory structure as a local checkout so _generate_bundle_core works.
# Sets DEPLOY_MODULES_DIR to the temp directory path.
# Usage: load_deploy_modules
load_deploy_modules() {
    echo "Downloading all modules for deploy bundle..." >&2

    DEPLOY_MODULES_DIR=$(mktemp -d /tmp/setup-k8s-deploy-modules-XXXXXX)
    _append_exit_trap "$DEPLOY_MODULES_DIR"

    mkdir -p "$DEPLOY_MODULES_DIR/lib"
    mkdir -p "$DEPLOY_MODULES_DIR/commands"

    # Download lib modules (bootstrap + all lib modules)
    local all_lib="bootstrap $_LIB_MODULES"
    for module in $all_lib; do
        echo "  - lib/${module}.sh" >&2
        _download_and_validate_module "${GITHUB_BASE_URL}/lib/${module}.sh" "$DEPLOY_MODULES_DIR/lib/${module}.sh" "lib/${module}.sh" || return 1
    done

    # Download command modules
    for module in $_COMMAND_MODULES; do
        echo "  - commands/${module}.sh" >&2
        _download_and_validate_module "${GITHUB_BASE_URL}/commands/${module}.sh" "$DEPLOY_MODULES_DIR/commands/${module}.sh" "commands/${module}.sh" || return 1
    done

    # Download distro modules (cleanup excluded — not needed for deploy bundle)
    for family in $_DISTRO_FAMILIES; do
        mkdir -p "$DEPLOY_MODULES_DIR/distros/$family"
        for module in $_DISTRO_MODULES; do
            [ "$module" = "cleanup" ] && continue
            echo "  - distros/${family}/${module}.sh" >&2
            _download_and_validate_module "${GITHUB_BASE_URL}/distros/${family}/${module}.sh" "$DEPLOY_MODULES_DIR/distros/${family}/${module}.sh" "distros/${family}/${module}.sh" || return 1
        done
    done

    # Download arch-specific AUR module
    mkdir -p "$DEPLOY_MODULES_DIR/distros/arch"
    echo "  - distros/arch/aur.sh" >&2
    _download_and_validate_module "${GITHUB_BASE_URL}/distros/arch/aur.sh" "$DEPLOY_MODULES_DIR/distros/arch/aur.sh" "distros/arch/aur.sh" || return 1

    # Download entry script (only setup-k8s.sh needed for deploy bundle)
    echo "  - setup-k8s.sh" >&2
    _download_and_validate_module "${GITHUB_BASE_URL}/setup-k8s.sh" "$DEPLOY_MODULES_DIR/setup-k8s.sh" "setup-k8s.sh" || return 1

    echo "All modules downloaded and validated" >&2
}
