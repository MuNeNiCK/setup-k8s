#!/bin/sh

set -eu

# === Sections ===
# 1. Environment setup & global defaults       (~line 8)
# 2. CLI argument parsing (pre-bootstrap)      (~line 38)
# 3. Bootstrap & runners sourcing              (~line 264)
# 4. Entry point (main)                       (~line 295)
#
# Subcommand runners -> lib/runners.sh

# Ensure /usr/local/bin is in PATH (generic distro installs binaries there)
case ":$PATH:" in
    *:/usr/local/bin:*) ;;
    *) export PATH="/usr/local/bin:$PATH" ;;
esac

# Ensure SUDO_USER is defined even when script runs as root without sudo
SUDO_USER="${SUDO_USER:-}"

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Detect stdin execution mode (curl | sh)
_STDIN_MODE=false
case "$0" in
    sh|dash|ash|bash|*/sh|*/dash|*/ash|*/bash|/dev/stdin|/proc/self/fd/0) _STDIN_MODE=true ;;
esac

# Default GitHub base URL (can be overridden)
GITHUB_BASE_URL="${GITHUB_BASE_URL:-https://raw.githubusercontent.com/MuNeNICK/setup-k8s/main}"

# Defaults for global flags parsed before modules are loaded
LOG_DIR="${LOG_DIR:-}"
_AUDIT_SYSLOG="${_AUDIT_SYSLOG:-false}"
COLLECT_DIAGNOSTICS="${COLLECT_DIAGNOSTICS:-false}"
RESUME_ENABLED="${RESUME_ENABLED:-false}"

# Check if running in bundled mode (all modules embedded in this script)
BUNDLED_MODE="${BUNDLED_MODE:-false}"

# Single-pass argument parsing: extract subcommand, global flags, and build cli_args
# before bootstrap to avoid unnecessary network fetch for --help.
# Subcommand is detected strictly from the first positional argument only,
# to avoid misinterpreting option values (e.g. --ha-interface deploy) as subcommands.
ACTION=""
_cli_argc=0
_action_detected=false
while [ $# -gt 0 ]; do
    arg="$1"
    # shellcheck disable=SC2034 # LOG_LEVEL used by logging module
    case "$arg" in
        --help|-h)
            # Deploy/upgrade/backup/restore/status --help is deferred to their parsers
            if [ "$_action_detected" = true ] && { [ "$ACTION" = "deploy" ] || [ "$ACTION" = "upgrade" ] || [ "$ACTION" = "remove" ] || [ "$ACTION" = "backup" ] || [ "$ACTION" = "restore" ] || [ "$ACTION" = "cleanup" ] || [ "$ACTION" = "status" ] || [ "$ACTION" = "preflight" ] || [ "$ACTION" = "renew" ]; }; then
                _cli_argc=$((_cli_argc + 1)); eval "_cli_${_cli_argc}=\$arg"
            else
                cat <<'HELPEOF'
Usage: setup-k8s.sh <init|join|deploy|upgrade|remove|backup|restore|cleanup|status|preflight|renew> [options]

Subcommands:
  init                    Initialize a new Kubernetes cluster
  join                    Join an existing cluster as a worker or control-plane node
  deploy                  Deploy a cluster across remote nodes via SSH
  upgrade                 Upgrade cluster Kubernetes version
  remove                  Remove nodes from the cluster (drain, delete, reset)
  backup                  Create an etcd snapshot backup
  restore                 Restore an etcd snapshot
  cleanup                 Clean up Kubernetes installation from this node
  status                  Show cluster and node status
  preflight               Run preflight checks before init/join
  renew                   Renew or check Kubernetes certificates

Options (init/join):
  --cri RUNTIME           Container runtime (containerd or crio). Default: containerd
  --proxy-mode MODE       Kube-proxy mode (iptables, ipvs, or nftables). Default: iptables
  --pod-network-cidr CIDR Pod network CIDR (e.g., 192.168.0.0/16)
  --apiserver-advertise-address ADDR  API server advertise address
  --control-plane-endpoint ENDPOINT   Control plane endpoint
  --service-cidr CIDR     Service CIDR (e.g., 10.96.0.0/12)
  --kubernetes-version VER Kubernetes version (e.g., 1.29, 1.28)
  --join-token TOKEN      Join token (join only)
  --join-address ADDR     Control plane address (join only)
  --discovery-token-hash HASH  Discovery token hash (join only)
  --control-plane         Join as control-plane node (join only, HA cluster)
  --certificate-key KEY   Certificate key for control-plane join
  --ha                    Enable HA mode with kube-vip (init only)
  --ha-vip ADDRESS        VIP address (required when --ha; also for join --control-plane)
  --ha-interface IFACE    Network interface for VIP (auto-detected if omitted)
  --swap-enabled          Keep swap enabled (K8s 1.28+, NodeSwap LimitedSwap)
  --distro FAMILY         Override distro family detection (debian, rhel, suse, arch, alpine, generic)
  --enable-completion BOOL  Enable shell completion setup (default: true)
  --completion-shells LIST  Shells to configure (auto, bash, zsh, fish, or comma-separated)
  --install-helm BOOL     Install Helm package manager (default: false)
  --install-kustomize BOOL  Install Kustomize (default: false)
  --dry-run               Show configuration summary and exit without making changes
  --verbose               Enable debug logging
  --quiet                 Suppress informational messages (errors only)
  --help, -h              Display this help message

Options (deploy):
  --control-planes IPs    Comma-separated control-plane nodes (user@ip or ip)
  --workers IPs           Comma-separated worker nodes (user@ip or ip)
  --ssh-user USER         Default SSH user (default: root)
  --ssh-port PORT         SSH port (default: 22)
  --ssh-key PATH          Path to SSH private key (auto-discovered from ~/.ssh/ when omitted)
  --ssh-password PASS     SSH password
  --ssh-known-hosts FILE  known_hosts file for host key verification (recommended)
  --ssh-host-key-check MODE  SSH host key policy: yes, no, or accept-new (default: accept-new)
  --ha-vip ADDRESS        VIP for HA (required when >1 control-plane)

  Run 'setup-k8s.sh deploy --help' for deploy-specific details.

Options (upgrade):
  --kubernetes-version VER  Target version in MAJOR.MINOR.PATCH format (e.g., 1.33.2)
  --first-control-plane     Run 'kubeadm upgrade apply' (first CP only)
  --skip-drain              Skip drain/uncordon (for single-node clusters)
  --control-planes IPs      Remote mode: comma-separated control-plane nodes
  --workers IPs             Remote mode: comma-separated worker nodes

  Run 'setup-k8s.sh upgrade --help' for upgrade-specific details.

Options (remove):
  --control-planes IP       Control-plane node (user@ip or ip)
  --workers IPs             Comma-separated nodes to remove (user@ip or ip)
  --force                   Skip confirmation prompt

  Run 'setup-k8s.sh remove --help' for details.

Options (cleanup):
  --force                 Skip confirmation prompt
  --preserve-cni          Preserve CNI configurations
  --remove-helm           Remove Helm binary and configuration
  --remove-kustomize      Remove Kustomize binary and configuration
  --dry-run               Show cleanup plan and exit

  Run 'setup-k8s.sh cleanup --help' for details.

Options (backup):
  --snapshot-path PATH    Output snapshot path (default: auto-generated)
  --control-planes IP     Remote mode: target control-plane node (user@ip or ip)

  Run 'setup-k8s.sh backup --help' for details.

Options (restore):
  --snapshot-path PATH    Snapshot file to restore (required)
  --control-planes IP     Remote mode: target control-plane node (user@ip or ip)

  Run 'setup-k8s.sh restore --help' for details.

Options (status):
  --output FORMAT         Output format: text (default) or wide

  Run 'setup-k8s.sh status --help' for details.

Options (preflight):
  --mode MODE             Check mode: init or join (default: init)
  --cri RUNTIME           Container runtime to check (default: containerd)
  --proxy-mode MODE       Proxy mode to check (default: iptables)
  --preflight-strict      Treat warnings as failures

  Run 'setup-k8s.sh preflight --help' for details.

Options (renew):
  --certs CERTS           Certificates to renew: 'all' or comma-separated list (default: all)
  --check-only            Only check certificate expiration (no renewal)
  --control-planes IPs    Remote mode: comma-separated control-plane nodes

  Run 'setup-k8s.sh renew --help' for details.
HELPEOF
                exit 0
            fi
            shift
            ;;
        --verbose)
            LOG_LEVEL=2
            shift
            ;;
        --quiet)
            LOG_LEVEL=0
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --log-dir)
            if [ $# -lt 2 ]; then
                echo "Error: --log-dir requires a value" >&2
                exit 1
            fi
            LOG_DIR="$2"
            shift 2
            ;;
        --audit-syslog)
            _AUDIT_SYSLOG=true
            shift
            ;;
        --collect-diagnostics)
            COLLECT_DIAGNOSTICS=true
            shift
            ;;
        --distro)
            if [ $# -lt 2 ]; then
                echo "Error: --distro requires a value" >&2
                exit 1
            fi
            DISTRO_OVERRIDE="$2"
            _cli_argc=$((_cli_argc + 1)); eval "_cli_${_cli_argc}=\$arg"
            _cli_argc=$((_cli_argc + 1)); eval "_cli_${_cli_argc}=\$2"
            shift 2
            ;;
        --resume)
            RESUME_ENABLED=true
            shift
            ;;
        --ha|--control-plane|--swap-enabled|--first-control-plane|--skip-drain|--no-rollback|--auto-step-upgrade|--force|--preserve-cni|--remove-helm|--remove-kustomize|--check-only|--preflight-strict)
            _cli_argc=$((_cli_argc + 1)); eval "_cli_${_cli_argc}=\$arg"
            shift
            ;;
        -*)
            # All other flags take a value: skip next token so it is never
            # interpreted as a subcommand. Pass both through to cli_args.
            if [ $# -lt 2 ]; then
                echo "Error: $arg requires a value" >&2
                exit 1
            fi
            _cli_argc=$((_cli_argc + 1)); eval "_cli_${_cli_argc}=\$arg"
            _cli_argc=$((_cli_argc + 1)); eval "_cli_${_cli_argc}=\$2"
            shift 2
            ;;
        *)
            # First non-flag positional argument is the subcommand (strip it from cli_args)
            if [ "$_action_detected" = false ]; then
                case "$arg" in
                    init|join|deploy|upgrade|remove|backup|restore|cleanup|status|preflight|renew)
                        ACTION="$arg"
                        _action_detected=true
                        shift
                        continue
                        ;;
                    *)
                        echo "Error: Unknown subcommand '$arg'. Valid subcommands: init, join, deploy, upgrade, remove, backup, restore, cleanup, status, preflight, renew" >&2
                        exit 1
                        ;;
                esac
            fi
            _cli_argc=$((_cli_argc + 1)); eval "_cli_${_cli_argc}=\$arg"
            shift
            ;;
    esac
done
unset _action_detected

# Inline helper: reconstruct cli_args into positional parameters.
# In POSIX sh, `set --` inside a function only affects function-local params.
# This macro must be used inline (not in a function) to modify the caller's $@.
# Usage: eval "$_RESTORE_CLI_ARGS"
_RESTORE_CLI_ARGS='set -- ; _i=1; while [ "$_i" -le "$_cli_argc" ]; do eval "set -- \"\$@\" \"\$_cli_${_i}\""; _i=$((_i + 1)); done'

# Check if --control-planes is present in args (determines remote vs local mode).
# Usage: eval "$_RESTORE_CLI_ARGS"; _has_control_planes_flag "$@"
_has_control_planes_flag() {
    for _arg in "$@"; do
        [ "$_arg" = "--control-planes" ] && return 0
    done
    return 1
}

# Source shared bootstrap logic (exit traps, module validation, _dispatch)
if ! type _validate_shell_module >/dev/null 2>&1; then
    if [ "$_STDIN_MODE" = false ] && [ -f "$SCRIPT_DIR/lib/bootstrap.sh" ]; then
        . "$SCRIPT_DIR/lib/bootstrap.sh"
    elif [ "$BUNDLED_MODE" = "true" ]; then
        echo "Error: Bundled mode via stdin requires a script with embedded modules." >&2
        exit 1
    else
        # Running standalone (e.g. curl | sh): download bootstrap.sh from GitHub
        _BOOTSTRAP_TMP=$(mktemp /tmp/bootstrap-XXXXXX)
        if curl -fsSL --retry 3 --retry-delay 2 "${GITHUB_BASE_URL}/lib/bootstrap.sh" > "$_BOOTSTRAP_TMP" && [ -s "$_BOOTSTRAP_TMP" ]; then
            # shellcheck disable=SC1090
            . "$_BOOTSTRAP_TMP"
            rm -f "$_BOOTSTRAP_TMP"
        else
            echo "Error: Failed to download bootstrap.sh from ${GITHUB_BASE_URL}" >&2
            rm -f "$_BOOTSTRAP_TMP"
            exit 1
        fi
    fi
fi

# Source runners (subcommand implementations)
if [ "$_STDIN_MODE" = false ] && [ -f "$SCRIPT_DIR/lib/runners.sh" ]; then
    . "$SCRIPT_DIR/lib/runners.sh"
elif [ "$_STDIN_MODE" = true ] && [ "$BUNDLED_MODE" != "true" ]; then
    _RUNNERS_TMP=$(mktemp /tmp/runners-XXXXXX)
    if curl -fsSL --retry 3 --retry-delay 2 "${GITHUB_BASE_URL}/lib/runners.sh" > "$_RUNNERS_TMP" && [ -s "$_RUNNERS_TMP" ]; then
        # shellcheck disable=SC1090
        . "$_RUNNERS_TMP"
        rm -f "$_RUNNERS_TMP"
    else
        echo "Error: Failed to download runners.sh from ${GITHUB_BASE_URL}" >&2
        rm -f "$_RUNNERS_TMP"
        exit 1
    fi
fi

main() {
    case "$ACTION" in
        deploy)          _run_deploy "$@" ;;
        upgrade)         _run_upgrade "$@" ;;
        remove)          _run_remove "$@" ;;
        cleanup)         _run_cleanup "$@" ;;
        backup|restore)  _run_etcd "$@" ;;
        preflight)       _run_preflight "$@" ;;
        renew)           _run_renew "$@" ;;
        status)          _run_status "$@" ;;
        init|join)       _run_setup "$@" ;;
        "")              _error_missing_subcommand ;;
    esac
}

main "$@"
