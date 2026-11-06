#!/bin/sh

set -eu

# Entry point. In a local checkout this file loads every module from lib/,
# commands/ and distros/. In the release bundle (dist/setup-k8s.sh) the
# modules are embedded above this code and BUNDLED_MODE=true.

# Ensure /usr/local/bin is in PATH (binary installs place tools there)
case ":$PATH:" in
    *:/usr/local/bin:*) ;;
    *) export PATH="/usr/local/bin:$PATH" ;;
esac

# Ensure SUDO_USER is defined even when the script runs as root without sudo
SUDO_USER="${SUDO_USER:-}"

SETUP_K8S_VERSION="${SETUP_K8S_VERSION:-dev}"
SETUP_K8S_RELEASE_URL="https://github.com/MuNeNiCK/setup-k8s/releases/latest/download/setup-k8s.sh"

# Path of the running bundle file, used to transfer the script to remote
# nodes. Empty when the bundle was read from stdin (curl ... | sh).
_SELF_PATH=""

if [ "${BUNDLED_MODE:-false}" = true ]; then
    if [ -f "$0" ] && head -n 3 "$0" 2>/dev/null | grep -q '^BUNDLED_MODE=true$'; then
        _SELF_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    fi
else
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    if [ ! -f "$SCRIPT_DIR/lib/bootstrap.sh" ]; then
        echo "Error: lib/ not found next to $0." >&2
        echo "Use the release bundle:" >&2
        echo "  curl -fsSL $SETUP_K8S_RELEASE_URL | sh -s -- <subcommand> [options]" >&2
        exit 1
    fi
    # shellcheck source=lib/bootstrap.sh
    . "$SCRIPT_DIR/lib/bootstrap.sh"
    _source_all_modules
fi

_SUBCOMMANDS="init join deploy upgrade remove backup restore cleanup status preflight renew"

_show_global_help() {
    cat <<'EOF'
Usage: setup-k8s.sh <subcommand> [options]

Subcommands:
  init        Initialize a new Kubernetes cluster on this node
  join        Join this node to an existing cluster
  deploy      Deploy a cluster across remote nodes via SSH
  upgrade     Upgrade the cluster Kubernetes version
  remove      Remove nodes from the cluster (drain, delete, reset)
  backup      Create an etcd snapshot backup
  restore     Restore an etcd snapshot
  cleanup     Remove the Kubernetes installation from this node
  status      Show cluster and node status
  preflight   Run preflight checks before init/join
  renew       Renew or check Kubernetes certificates

Global options:
  --dry-run               Show what would be done and exit
  --verbose               Enable debug logging
  --quiet                 Suppress informational messages (errors only)
  --log-dir DIR           Also write logs to a file in DIR
  --audit-syslog          Send audit events to syslog
  --collect-diagnostics   Collect diagnostics on failure
  --resume                Resume an interrupted operation
  --version               Print the version and exit
  --help, -h              Display this help message

Run 'setup-k8s.sh <subcommand> --help' for subcommand options.
EOF
}

_show_subcommand_help() {
    case "$1" in
        init|join) show_setup_help ;;
        deploy)    show_deploy_help ;;
        upgrade)   show_upgrade_help ;;
        remove)    show_remove_help ;;
        backup)    show_backup_help ;;
        restore)   show_restore_help ;;
        cleanup)   show_cleanup_help ;;
        status)    show_status_help ;;
        preflight) show_preflight_help ;;
        renew)     show_renew_help ;;
    esac
}

# shellcheck disable=SC2034 # global flags are read by the loaded modules
_main() {
    local _help=false _rest=""
    ACTION=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --verbose) LOG_LEVEL=2 ;;
            --quiet) LOG_LEVEL=0 ;;
            --dry-run) DRY_RUN=true ;;
            --log-dir)
                if [ $# -lt 2 ]; then
                    echo "Error: --log-dir requires a value" >&2
                    exit 1
                fi
                LOG_DIR="$2"
                shift
                ;;
            --audit-syslog) _AUDIT_SYSLOG=true ;;
            --collect-diagnostics) COLLECT_DIAGNOSTICS=true ;;
            --resume) RESUME_ENABLED=true ;;
            --version)
                echo "setup-k8s ${SETUP_K8S_VERSION}"
                exit 0
                ;;
            --help|-h) _help=true ;;
            *)
                if [ -n "$ACTION" ]; then
                    _rest="${_rest}$(_posix_shell_quote "$1")"
                else
                    case " $_SUBCOMMANDS " in
                        *" $1 "*) ACTION="$1" ;;
                        *)
                            case "$1" in
                                -*) echo "Error: '$1' must follow the subcommand (setup-k8s.sh <subcommand> [options])" >&2 ;;
                                *)  echo "Error: Unknown subcommand '$1'. Valid subcommands: $_SUBCOMMANDS" >&2 ;;
                            esac
                            exit 1
                            ;;
                    esac
                fi
                ;;
        esac
        shift
    done

    if [ "$_help" = true ]; then
        if [ -n "$ACTION" ]; then
            _show_subcommand_help "$ACTION"
        else
            _show_global_help
        fi
        exit 0
    fi
    if [ -z "$ACTION" ]; then
        echo "Error: Missing subcommand. Valid subcommands: $_SUBCOMMANDS" >&2
        echo "Run with --help for usage information" >&2
        exit 1
    fi

    if [ -n "${LOG_DIR:-}" ]; then
        _init_file_logging "$LOG_DIR"
    fi

    eval "set -- $_rest"
    case "$ACTION" in
        init|join)      _run_setup "$@" ;;
        deploy)         _run_deploy "$@" ;;
        upgrade)        _run_upgrade "$@" ;;
        remove)         _run_remove "$@" ;;
        backup|restore) _run_etcd "$@" ;;
        cleanup)        _run_cleanup "$@" ;;
        status)         _run_status "$@" ;;
        preflight)      _run_preflight "$@" ;;
        renew)          _run_renew "$@" ;;
    esac
}

_main "$@"
