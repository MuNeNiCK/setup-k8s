#!/bin/sh
# shellcheck disable=SC2034 # variables are used by sourcing scripts

# Log level: 0=quiet, 1=normal (default), 2=verbose
LOG_LEVEL="${LOG_LEVEL:-1}"

# Dry-run mode
DRY_RUN="${DRY_RUN:-false}"

# File logging directory (empty = disabled)
LOG_DIR="${LOG_DIR:-}"

# Audit syslog (send audit events to syslog via logger)
_AUDIT_SYSLOG="${_AUDIT_SYSLOG:-false}"

# Collect diagnostics on failure
COLLECT_DIAGNOSTICS="${COLLECT_DIAGNOSTICS:-false}"

# Default values for global variables
K8S_VERSION=""
ACTION="${ACTION:-}"  # init or join (set by subcommand)
JOIN_TOKEN=""
JOIN_ADDRESS=""
DISCOVERY_TOKEN_HASH=""
DISTRO_OVERRIDE="${DISTRO_OVERRIDE:-}"  # Manual distro family override (debian, rhel, suse, arch, generic)
DISTRO_NAME=""
DISTRO_VERSION=""
DISTRO_FAMILY=""
CRI="containerd"  # Container runtime interface (containerd, crio, etc.)
PROXY_MODE="iptables"  # iptables, ipvs, or nftables (nftables requires K8s 1.29+)
SWAP_ENABLED=false  # Keep swap enabled (K8s 1.28+, NodeSwap feature)

# HA cluster support
JOIN_AS_CONTROL_PLANE=false
CERTIFICATE_KEY=""
HA_ENABLED=false
HA_VIP_ADDRESS=""
HA_VIP_INTERFACE=""

# Additional variables for cleanup
FORCE=false
PRESERVE_CNI=false

# Kubeadm configuration (parsed from CLI args)
KUBEADM_POD_CIDR=""
KUBEADM_SERVICE_CIDR=""
KUBEADM_API_ADDR=""
KUBEADM_CP_ENDPOINT=""

# Shell completion variables
ENABLE_COMPLETION=true  # Enable shell completion setup for kubectl, kubeadm, etc.
INSTALL_HELM=false  # Install Helm package manager
INSTALL_KUSTOMIZE=false  # Install Kustomize
COMPLETION_SHELLS="auto"  # auto, bash, zsh, fish, or comma-separated list

# Deploy subcommand
DEPLOY_CONTROL_PLANES=""
DEPLOY_WORKERS=""
DEPLOY_SSH_USER="root"
DEPLOY_SSH_PORT="22"
DEPLOY_SSH_KEY=""
DEPLOY_SSH_PASSWORD="${DEPLOY_SSH_PASSWORD:-}"
DEPLOY_SSH_PASSWORD_FILE=""
DEPLOY_SSH_KNOWN_HOSTS_FILE=""
DEPLOY_SSH_HOST_KEY_CHECK="${DEPLOY_SSH_HOST_KEY_CHECK:-accept-new}"
DEPLOY_PERSIST_KNOWN_HOSTS=""
DEPLOY_PASSTHROUGH_ARGS=""

# Upgrade subcommand
UPGRADE_TARGET_VERSION=""            # MAJOR.MINOR.PATCH (e.g., 1.33.2)
UPGRADE_FIRST_CONTROL_PLANE=false    # kubeadm upgrade apply (first CP) vs kubeadm upgrade node
UPGRADE_SKIP_DRAIN=false             # Skip drain/uncordon in remote mode
UPGRADE_PASSTHROUGH_ARGS=""          # Arguments to forward to remote nodes
UPGRADE_NO_ROLLBACK=false            # Disable automatic rollback on failure
UPGRADE_AUTO_STEP=false              # Automatically step through minor versions

# Remove subcommand
REMOVE_CONTROL_PLANES=""             # remove: CP node (user@ip)
REMOVE_NODES=""                      # remove: target nodes (comma-separated)
REMOVE_PASSTHROUGH_ARGS=""           # remove: args to forward

# Backup/Restore subcommand
ETCD_SNAPSHOT_PATH=""         # snapshot file path (backup: output, restore: input)
ETCD_CONTROL_PLANES=""        # remote mode: target control-plane node (user@ip or ip)
ETCD_PASSTHROUGH_ARGS=""      # arguments to forward to remote nodes

# Status subcommand
STATUS_OUTPUT_FORMAT="text"   # output format: text or wide

# Preflight subcommand
PREFLIGHT_MODE="init"
PREFLIGHT_CRI="containerd"
PREFLIGHT_PROXY_MODE="iptables"
PREFLIGHT_K8S_VERSION=""
PREFLIGHT_STRICT=false  # Treat WARN as FAIL in preflight checks

# Renew subcommand
RENEW_CERTS="all"
RENEW_CHECK_ONLY=false
RENEW_PASSTHROUGH_ARGS=""

# kubeadm config patch file (appended to generated config)
KUBEADM_CONFIG_PATCH=""
# Extra SANs for API server certificate
API_SERVER_EXTRA_SANS=""
# Kubelet node-ip override
KUBELET_NODE_IP=""

# Version constants (overridable via environment)
KUBE_VIP_VERSION="${KUBE_VIP_VERSION:-v0.8.9}"
PAUSE_IMAGE_VERSION="${PAUSE_IMAGE_VERSION:-3.10}"

# Component version defaults for generic distro (overridable via environment)
CONTAINERD_VERSION="${CONTAINERD_VERSION:-2.0.4}"
RUNC_VERSION="${RUNC_VERSION:-1.2.5}"
CNI_PLUGINS_VERSION="${CNI_PLUGINS_VERSION:-1.6.2}"
CRIO_VERSION="${CRIO_VERSION:-}"
# Timeout for remote operations (seconds)
DEPLOY_REMOTE_TIMEOUT="${DEPLOY_REMOTE_TIMEOUT:-600}"
# Polling interval for remote operations (seconds)
DEPLOY_POLL_INTERVAL="${DEPLOY_POLL_INTERVAL:-10}"

# Bundle module list: bootstrap + _COMMON_MODULES (defined in bootstrap.sh)
BUNDLE_COMMON_MODULES="bootstrap ${_COMMON_MODULES:-}"

# Resume support
RESUME_ENABLED=false  # Resume from a previous interrupted operation

# Cleanup options
REMOVE_HELM=false  # Remove Helm during cleanup (opt-in via --remove-helm)
REMOVE_KUSTOMIZE=false  # Remove Kustomize during cleanup (opt-in via --remove-kustomize)
