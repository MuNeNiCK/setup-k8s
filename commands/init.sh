#!/bin/sh

# === Setup argument parsing (init/join) ===

# Help message for init/join
show_setup_help() {
    cat <<'EOF'
Usage: setup-k8s.sh init [options]
       setup-k8s.sh join ADDR --token TOKEN --discovery-token-ca-cert-hash HASH [options]

Initialize a new cluster on this node (init) or join this node to an existing
cluster (join). Must be run as root.

Options (init and join):
  --cri RUNTIME             Container runtime: containerd or crio (default: containerd)
  --proxy-mode MODE         kube-proxy mode: auto, iptables, ipvs, or nftables (default: auto =
                            nftables on Kubernetes 1.33+ with kernel 5.13+, otherwise iptables)
  --kubernetes-version VER  Kubernetes version: MAJOR.MINOR (latest patch) or MAJOR.MINOR.PATCH
                            (pinned), e.g. 1.37 or 1.37.2 (default: latest stable)
  --prerelease              Install the next release from the prerelease channels
                            (pkgs.k8s.io / isv:cri-o prerelease; default version: latest)
  --image-repository REPO   Pull control-plane images from REPO instead of registry.k8s.io
  --patches DIR             Apply kubeadm patches from DIR (as kubeadm --patches) on init and join
  --kubelet-node-ip IP      Set the kubelet node IP
  --swap-enabled            Keep swap enabled (NodeSwap, LimitedSwap; Kubernetes 1.30+)
  --distro FAMILY           Override distro family detection (debian, rhel, suse, arch, alpine, generic)
  --http-proxy URL          HTTP proxy for downloads and image pulls (default: $http_proxy)
  --https-proxy URL         HTTPS proxy (default: $https_proxy)
  --no-proxy LIST           Extra destinations without the proxy (default: $no_proxy); the
                            cluster's own addresses and networks are always added
  --enable-completion BOOL  Set up shell completion (default: true)
  --completion-shells LIST  Shells to configure: auto, bash, zsh, fish, or a comma-separated list
  --install-helm BOOL       Install Helm (default: false)
  --install-kustomize BOOL  Install Kustomize (default: false)

Options (init):
  --pod-network-cidr CIDR             Pod network CIDR (e.g. 192.168.0.0/16)
  --service-cidr CIDR                 Service CIDR (e.g. 10.96.0.0/12)
  --apiserver-advertise-address ADDR  API server advertise address
  --control-plane-endpoint ENDPOINT   Control plane endpoint
  --apiserver-cert-extra-sans LIST    Extra SANs for the API server certificate (comma-separated)
  --kubeadm-config-patch FILE         Merge a kubeadm config file into the generated config
  --ha                                Enable HA mode with kube-vip (requires --ha-vip)
  --ha-vip ADDRESS                    Virtual IP address for HA
  --ha-interface IFACE                Network interface for the VIP (auto-detected if omitted)

Options (join; the names follow kubeadm join):
  ADDR, --join-address ADDR             API server address (host:port), as the first argument or option
  --token TOKEN                         Bootstrap token
  --discovery-token-ca-cert-hash HASH   CA certificate hash (sha256:...)
  --control-plane                       Join as a control-plane node (HA)
  --certificate-key KEY                 Certificate key for control-plane join
  --ha-vip ADDRESS                      Virtual IP address (with --control-plane)
  --ha-interface IFACE                  Network interface for the VIP

Global options such as --dry-run, --verbose and --log-dir are listed in
'setup-k8s.sh --help'.
EOF
    exit "${1:-0}"
}

# Parse command line arguments for setup
parse_setup_args() {
    while [ $# -gt 0 ]; do
        case $1 in
            --cri)
                _require_value $# "$1" "${2:-}"
                CRI="$2"
                shift 2
                ;;
            --kubernetes-version)
                _require_value $# "$1" "${2:-}"
                # MAJOR.MINOR (latest patch) or MAJOR.MINOR.PATCH (pinned)
                if ! echo "$2" | grep -qE '^[0-9]+\.[0-9]+(\.[0-9]+)?$'; then
                    log_error "--kubernetes-version must be MAJOR.MINOR or MAJOR.MINOR.PATCH (e.g., 1.37 or 1.37.2), got '$2'"
                    exit 1
                fi
                K8S_VERSION=$(_k8s_minor_version "$2")
                # shellcheck disable=SC2034 # used by lib/components/kubernetes.sh
                case "$2" in
                    *.*.*) K8S_PATCH_VERSION="$2" ;;
                esac
                shift 2
                ;;
            --prerelease)
                # shellcheck disable=SC2034 # used by lib/components and lib/core/k8s_version.sh
                K8S_PRERELEASE=true
                shift
                ;;
            --image-repository)
                _require_value $# "$1" "${2:-}"
                # shellcheck disable=SC2034 # used by lib/node/kubeadm.sh
                KUBEADM_IMAGE_REPOSITORY="$2"
                shift 2
                ;;
            --patches)
                _require_value $# "$1" "${2:-}"
                if [ ! -d "$2" ]; then
                    log_error "--patches directory not found: $2"
                    exit 1
                fi
                # shellcheck disable=SC2034 # used by lib/node/kubeadm.sh
                KUBEADM_PATCHES_DIR=$(cd "$2" && pwd)
                shift 2
                ;;
            --token)
                _require_value $# "$1" "${2:-}"
                # shellcheck disable=SC2034 # used by validation.sh
                JOIN_TOKEN="$2"
                shift 2
                ;;
            --join-address)
                _require_value $# "$1" "${2:-}"
                # shellcheck disable=SC2034 # used by validation.sh
                JOIN_ADDRESS="$2"
                shift 2
                ;;
            --discovery-token-ca-cert-hash)
                _require_value $# "$1" "${2:-}"
                # shellcheck disable=SC2034 # used by validation.sh
                DISCOVERY_TOKEN_HASH="$2"
                shift 2
                ;;
            --proxy-mode)
                _require_value $# "$1" "${2:-}"
                PROXY_MODE="$2"
                shift 2
                ;;
            --control-plane)
                # shellcheck disable=SC2034 # used by validation.sh
                JOIN_AS_CONTROL_PLANE=true
                shift
                ;;
            --certificate-key)
                _require_value $# "$1" "${2:-}"
                # shellcheck disable=SC2034 # used by validation.sh
                CERTIFICATE_KEY="$2"
                shift 2
                ;;
            --ha)
                HA_ENABLED=true
                shift
                ;;
            --ha-vip)
                _require_value $# "$1" "${2:-}"
                HA_VIP_ADDRESS="$2"
                shift 2
                ;;
            --ha-interface)
                _require_value $# "$1" "${2:-}"
                # shellcheck disable=SC2034 # used by kubevip.sh
                HA_VIP_INTERFACE="$2"
                shift 2
                ;;
            --enable-completion)
                _require_value $# "$1" "${2:-}"
                # shellcheck disable=SC2034 # used by validation.sh
                ENABLE_COMPLETION="$2"
                shift 2
                ;;
            --install-helm)
                _require_value $# "$1" "${2:-}"
                # shellcheck disable=SC2034 # used by validation.sh
                INSTALL_HELM="$2"
                shift 2
                ;;
            --install-kustomize)
                _require_value $# "$1" "${2:-}"
                # shellcheck disable=SC2034 # used by validation.sh
                INSTALL_KUSTOMIZE="$2"
                shift 2
                ;;
            --completion-shells)
                _require_value $# "$1" "${2:-}"
                # shellcheck disable=SC2034 # used by completion.sh
                COMPLETION_SHELLS="$2"
                shift 2
                ;;
            --pod-network-cidr)
                _require_value $# "$1" "${2:-}"
                _validate_cidr "$2" "$1"
                # shellcheck disable=SC2034 # used by helpers.sh
                KUBEADM_POD_CIDR="$2"
                shift 2
                ;;
            --service-cidr)
                _require_value $# "$1" "${2:-}"
                _validate_cidr "$2" "$1"
                # shellcheck disable=SC2034 # used by helpers.sh
                KUBEADM_SERVICE_CIDR="$2"
                shift 2
                ;;
            --apiserver-advertise-address)
                _require_value $# "$1" "${2:-}"
                # shellcheck disable=SC2034 # used by helpers.sh
                KUBEADM_API_ADDR="$2"
                shift 2
                ;;
            --control-plane-endpoint)
                _require_value $# "$1" "${2:-}"
                KUBEADM_CP_ENDPOINT="$2"
                shift 2
                ;;
            --swap-enabled)
                SWAP_ENABLED=true
                shift
                ;;
            --kubeadm-config-patch)
                _require_value $# "$1" "${2:-}"
                # shellcheck disable=SC2034 # used by helpers.sh
                KUBEADM_CONFIG_PATCH="$2"
                shift 2
                ;;
            --apiserver-cert-extra-sans)
                _require_value $# "$1" "${2:-}"
                # shellcheck disable=SC2034 # used by helpers.sh
                API_SERVER_EXTRA_SANS="$2"
                shift 2
                ;;
            --kubelet-node-ip)
                _require_value $# "$1" "${2:-}"
                # shellcheck disable=SC2034 # used by helpers.sh
                KUBELET_NODE_IP="$2"
                shift 2
                ;;
            *)
                if _is_distro_flag "$1"; then
                    _parse_distro_flag $# "$1" "${2:-}"
                    shift "$_DISTRO_SHIFT"
                elif _is_proxy_flag "$1"; then
                    _parse_proxy_flag $# "$1" "${2:-}"
                    shift "$_PROXY_SHIFT"
                elif [ "$ACTION" = join ] && [ -z "$JOIN_ADDRESS" ] && [ "${1#-}" = "$1" ]; then
                    # kubeadm join <api-server-endpoint>
                    JOIN_ADDRESS="$1"
                    shift
                else
                    log_error "Unknown option: $1"
                    log_error "Run with --help for usage information"
                    exit 1
                fi
                ;;
        esac
    done
}

# === Cluster Initialization (init subcommand) ===
# Kubeadm config generation helpers → lib/node/kubeadm.sh

# Initialize Kubernetes cluster
initialize_cluster() {
    log_info "Initializing cluster..."

    # Deploy kube-vip before kubeadm init if HA is enabled
    if [ "$HA_ENABLED" = true ]; then
        deploy_kube_vip || return 1
    fi

    _configure_kubelet_node_ip

    # Run kubeadm init, capturing exit code for rollback
    local init_exit=0 CONFIG_FILE
    if ! CONFIG_FILE=$(generate_kubeadm_config); then
        log_error "Failed to generate kubeadm configuration"
        if [ "$HA_ENABLED" = true ]; then
            _rollback_vip
        fi
        return 1
    fi
    log_info "Using kubeadm configuration file: $CONFIG_FILE"
    # shellcheck disable=SC2046 # intentional word splitting
    kubeadm init --config "$CONFIG_FILE" $(_kubeadm_preflight_ignore_args) || init_exit=$?
    rm -f "$CONFIG_FILE"

    if [ "$init_exit" -ne 0 ]; then
        log_error "kubeadm init failed (exit code: $init_exit)"
        if [ "$HA_ENABLED" = true ]; then
            _rollback_vip
        fi
        return "$init_exit"
    fi

    # Verify kube-vip kubeconfig exists after init
    if [ "$HA_ENABLED" = true ]; then
        _verify_kube_vip_kubeconfig
    fi

    _configure_kubectl

    # Display join command for worker nodes
    log_info "Displaying join command for worker nodes..."
    kubeadm token create --print-join-command

    # For HA clusters, upload certs and display control-plane join command
    if [ "$HA_ENABLED" = true ]; then
        log_info ""
        log_info "=== HA Cluster: Control-Plane Join Information ==="
        local cert_output cert_key
        if ! cert_output=$(kubeadm init phase upload-certs --upload-certs); then
            log_error "kubeadm upload-certs failed: additional control planes cannot join"
            log_error "  The first control plane is initialized; retry with: kubeadm init phase upload-certs --upload-certs"
            return 1
        fi
        cert_key=$(echo "$cert_output" | tail -1)
        if ! echo "$cert_key" | grep -qE '^[a-f0-9]{64}$'; then
            log_error "Invalid certificate key format (expected 64 hex chars, got: '$cert_key')"
            return 1
        fi
        log_info "Certificate key: $cert_key"
        log_info ""
        log_info "To join additional control-plane nodes, run:"
        log_info "  setup-k8s.sh join <address> --token <token> --discovery-token-ca-cert-hash <hash> \\"
        log_info "    --control-plane --certificate-key $cert_key --ha-vip ${HA_VIP_ADDRESS}"
        log_info "================================================="
    fi

    log_info "Cluster initialization complete!"
    log_info "Next steps:"
    log_info "1. Install a CNI plugin"
    log_info "2. For single-node clusters, remove the taint with:"
    log_info "   kubectl taint nodes --all node-role.kubernetes.io/control-plane-"
}

# === Setup runner (init/join) ===

# Show dry-run configuration summary for init/join
_setup_dry_run() {
    log_info "=== Dry-run Configuration Summary ==="
    log_info "Action: ${ACTION}"
    log_info "Container Runtime: ${CRI}"
    log_info "Proxy mode: ${PROXY_MODE}"
    log_info "Kubernetes Version (minor): ${K8S_VERSION}"
    log_info "Distribution: ${DISTRO_NAME:-unknown} (family: ${DISTRO_FAMILY:-unknown})"
    log_info "Swap enabled: ${SWAP_ENABLED}"
    log_info "Install Helm: ${INSTALL_HELM}"
    log_info "Install Kustomize: ${INSTALL_KUSTOMIZE}"
    log_info "Shell Completion: ${ENABLE_COMPLETION} (shells: ${COMPLETION_SHELLS})"
    [ -n "$KUBEADM_POD_CIDR" ] && log_info "Pod network CIDR: $KUBEADM_POD_CIDR"
    [ -n "$KUBEADM_SERVICE_CIDR" ] && log_info "Service CIDR: $KUBEADM_SERVICE_CIDR"
    [ -n "$KUBEADM_API_ADDR" ] && log_info "API server address: $KUBEADM_API_ADDR"
    [ -n "$KUBEADM_CP_ENDPOINT" ] && log_info "Control plane endpoint: $KUBEADM_CP_ENDPOINT"
    if [ "$JOIN_AS_CONTROL_PLANE" = true ]; then
        log_info "HA Mode: joining as control-plane"
    fi
    if [ "$HA_ENABLED" = true ]; then
        log_info "HA Mode: kube-vip enabled"
        log_info "HA VIP: ${HA_VIP_ADDRESS}"
        log_info "HA Interface: ${HA_VIP_INTERFACE}"
    fi
    log_info "=== End of dry-run (no changes made) ==="
}

# Common pre-cleanup steps shared by all distributions
cleanup_pre_common() {
    log_info "Resetting cluster state..."
    kubeadm reset -f || true
    cleanup_cni
}

_run_setup() {
    _require_root "This script"

    parse_setup_args "$@"
    validate_join_args
    validate_cri
    validate_completion_options

    if [ -z "${DISTRO_FAMILY:-}" ]; then
        detect_distribution
    fi
    # Downloads (version lookup, packages) go through the proxy, if any
    proxy_apply_env

    # A dry run changes nothing: no package installs or index refreshes, and
    # no host preparation. Values that need missing tools (curl) are reported
    # as resolved at install time.
    if [ "$DRY_RUN" = true ]; then
        if ! command -v curl >/dev/null 2>&1 && [ -z "$K8S_VERSION" ] && [ "${DISTRO_K8S_SOURCE:-}" != distro ]; then
            log_info "curl is not installed; the latest stable Kubernetes version is resolved during setup"
            K8S_VERSION="(latest stable)"
        else
            determine_k8s_version || exit 1
        fi
        resolve_proxy_mode
        case "$K8S_VERSION" in
            [0-9]*) validate_proxy_mode; validate_swap_enabled ;;
        esac
        validate_ha_args
        _setup_dry_run
        exit 0
    fi

    log_info "Installing dependencies..."
    install_node_dependencies
    determine_k8s_version
    resolve_proxy_mode
    validate_proxy_mode
    validate_swap_enabled
    validate_ha_args

    _audit_start "$ACTION" "version=${K8S_VERSION} cri=${CRI} proxy=${PROXY_MODE}"
    log_info "Starting Kubernetes initialization script..."
    log_info "Action: ${ACTION}"
    log_info "Container Runtime: ${CRI}"
    log_info "Proxy mode: ${PROXY_MODE}"
    log_info "Swap enabled: ${SWAP_ENABLED}"
    log_info "Kubernetes Version (minor): ${K8S_VERSION}"

    if [ "$SWAP_ENABLED" != true ]; then
        disable_swap
        disable_zram_swap
    fi

    install_proxy_mode_packages
    enable_kernel_modules
    configure_network_settings

    if [ "$PROXY_MODE" = "ipvs" ]; then
        check_ipvs_availability
    fi
    if [ "$PROXY_MODE" = "nftables" ]; then
        check_nftables_availability
    fi

    # Kubernetes first: the container runtime is configured with the pause
    # image of the installed kubeadm. kubelet restarts until kubeadm runs.
    log_info "Setting up Kubernetes..."
    k8s_install

    log_info "Setting up container runtime: ${CRI}..."
    if [ "$CRI" = "containerd" ]; then
        containerd_install
        proxy_verify_runtime containerd
    else
        crio_install
        proxy_verify_runtime crio
    fi

    log_info "Performing pre-installation cleanup..."
    cleanup_pre_common
    cleanup_kube_configs
    reset_iptables

    if [ "$ACTION" = "init" ]; then
        initialize_cluster
    else
        join_cluster
    fi

    show_versions
    setup_helm
    setup_kustomize
    setup_k8s_shell_completion
    _audit_done
    log_info "Setup completed successfully!"
}

# Check required arguments for join
validate_join_args() {
    if [ "$ACTION" = "join" ]; then
        if [ -z "$JOIN_TOKEN" ] || [ -z "$JOIN_ADDRESS" ] || [ -z "$DISCOVERY_TOKEN_HASH" ]; then
            log_error "join requires --token, --join-address, and --discovery-token-ca-cert-hash"
            exit 1
        fi
        if ! _validate_join_token_format "$JOIN_TOKEN" "--token"; then
            exit 1
        fi
        if ! _validate_discovery_hash_format "$DISCOVERY_TOKEN_HASH" "--discovery-token-ca-cert-hash"; then
            exit 1
        fi
        # Validate join address format: host:port (host part must be non-empty)
        if ! echo "$JOIN_ADDRESS" | grep -qE '^.+:[0-9]+$'; then
            log_error "--join-address should include a port (e.g., 192.168.1.10:6443 or [::1]:6443, got: $JOIN_ADDRESS)"
            exit 1
        fi
        local _join_port="${JOIN_ADDRESS##*:}"
        if [ "$_join_port" -lt 1 ] || [ "$_join_port" -gt 65535 ]; then
            log_error "--join-address port out of range (1-65535, got: $_join_port)"
            exit 1
        fi
        # Validate HA control-plane join args
        if [ "$JOIN_AS_CONTROL_PLANE" = true ] && [ -z "$CERTIFICATE_KEY" ]; then
            log_error "--control-plane requires --certificate-key"
            exit 1
        fi
    fi
}

# Validate CRI selection
validate_cri() {
    case "$CRI" in
        containerd|crio) ;;
        *) log_error "Unsupported CRI '$CRI'. Supported options are: containerd, crio"; exit 1 ;;
    esac
}

# Validate shell completion options
validate_completion_options() {
    if [ "$ENABLE_COMPLETION" != "true" ] && [ "$ENABLE_COMPLETION" != "false" ]; then
        log_error "--enable-completion must be 'true' or 'false'"
        exit 1
    fi

    if [ "$INSTALL_HELM" != "true" ] && [ "$INSTALL_HELM" != "false" ]; then
        log_error "--install-helm must be 'true' or 'false'"
        exit 1
    fi

    if [ "$INSTALL_KUSTOMIZE" != "true" ] && [ "$INSTALL_KUSTOMIZE" != "false" ]; then
        log_error "--install-kustomize must be 'true' or 'false'"
        exit 1
    fi

    if [ "$COMPLETION_SHELLS" != "auto" ]; then
        _validate_single_shell() {
            local shell_name
            shell_name=$(echo "$1" | tr -d ' ')
            case "$shell_name" in
                bash|zsh|fish) ;;
                *)
                    log_error "Invalid shell '$shell_name' in --completion-shells. Valid options are: bash, zsh, fish, or 'auto'"
                    exit 1
                    ;;
            esac
        }
        _csv_for_each "$COMPLETION_SHELLS" _validate_single_shell
    fi
}

# Validate proxy mode selection
validate_proxy_mode() {
    if [ "$PROXY_MODE" != "iptables" ] && [ "$PROXY_MODE" != "ipvs" ] && [ "$PROXY_MODE" != "nftables" ]; then
        log_error "Proxy mode must be 'auto', 'iptables', 'ipvs', or 'nftables'"
        exit 1
    fi

    if [ "$PROXY_MODE" = "ipvs" ] && k8s_supports ipvs-deprecated; then
        log_warn "ipvs proxy mode is deprecated in Kubernetes $(k8s_feature_min ipvs-deprecated)+; migrate to nftables when possible"
    fi

    if [ "$PROXY_MODE" = "nftables" ]; then
        if ! k8s_supports nftables; then
            log_error "nftables proxy mode requires Kubernetes $(k8s_feature_min nftables) or higher"
            log_error "Current version: $K8S_VERSION"
            log_error "Please use --kubernetes-version $(k8s_feature_min nftables) or higher, or choose a different proxy mode"
            exit 1
        fi
        if ! k8s_supports nftables-beta; then
            log_warn "nftables is in alpha status in Kubernetes $K8S_VERSION (beta from $(k8s_feature_min nftables-beta))"
        fi
    fi
}

# Validate swap enabled option (requires NodeSwap support)
validate_swap_enabled() {
    if [ "$SWAP_ENABLED" = true ] && [ -n "$K8S_VERSION" ] && ! k8s_supports swap; then
        log_error "--swap-enabled requires Kubernetes $(k8s_feature_min swap)+ (got: $K8S_VERSION)"
        exit 1
    fi
}

# Validate HA arguments
validate_ha_args() {
    if [ "$HA_ENABLED" = true ]; then
        if [ "$ACTION" != "init" ]; then
            log_error "--ha is only valid with the 'init' subcommand"
            exit 1
        fi
        if [ -z "$HA_VIP_ADDRESS" ]; then
            log_error "--ha requires --ha-vip ADDRESS"
            exit 1
        fi
    fi

    # On init, --ha-vip requires --ha (otherwise kube-vip is not deployed)
    if [ -n "$HA_VIP_ADDRESS" ] && [ "$ACTION" = "init" ] && [ "$HA_ENABLED" = false ]; then
        log_error "--ha-vip with init requires --ha flag"
        exit 1
    fi

    # VIP address applies to both init --ha and join --control-plane
    if [ -n "$HA_VIP_ADDRESS" ]; then
        if _is_ipv6 "$HA_VIP_ADDRESS"; then
            # Validate IPv6 VIP address
            _validate_ipv6_addr "$HA_VIP_ADDRESS" "--ha-vip"
        else
            # Validate IPv4 VIP address
            if ! echo "$HA_VIP_ADDRESS" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
                log_error "--ha-vip must be a valid IPv4 address (got: $HA_VIP_ADDRESS)"
                exit 1
            fi
            local _vo1 _vo2 _vo3 _vo4
            IFS='.' read -r _vo1 _vo2 _vo3 _vo4 <<EOF
$HA_VIP_ADDRESS
EOF
            if [ "$_vo1" -gt 255 ] || [ "$_vo2" -gt 255 ] || [ "$_vo3" -gt 255 ] || [ "$_vo4" -gt 255 ]; then
                log_error "--ha-vip octets out of range (got: $HA_VIP_ADDRESS)"
                exit 1
            fi
        fi
        # On join, --ha-vip requires --control-plane
        if [ "$ACTION" = "join" ] && [ "$JOIN_AS_CONTROL_PLANE" != true ]; then
            log_error "--ha-vip on join requires --control-plane"
            exit 1
        fi
        # Auto-detect interface if not specified
        if [ -z "$HA_VIP_INTERFACE" ]; then
            local _iproute_out
            if _is_ipv6 "$HA_VIP_ADDRESS"; then
                # IPv6: use ip -6 route get
                if ! _iproute_out=$(ip -6 route get ::1 2>&1); then
                    log_error "Could not auto-detect network interface. Please specify --ha-interface"
                    [ -n "$_iproute_out" ] && log_error "  ip route error: $_iproute_out"
                    exit 1
                fi
                HA_VIP_INTERFACE=$(echo "$_iproute_out" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
            else
                # IPv4: use ip route get
                if ! _iproute_out=$(ip route get 1 2>&1); then
                    log_error "Could not auto-detect network interface. Please specify --ha-interface"
                    [ -n "$_iproute_out" ] && log_error "  ip route error: $_iproute_out"
                    exit 1
                fi
                HA_VIP_INTERFACE=$(echo "$_iproute_out" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
            fi
            if [ -z "$HA_VIP_INTERFACE" ]; then
                log_error "Could not auto-detect network interface. Please specify --ha-interface"
                exit 1
            fi
        fi
        # Validate interface name (alphanumeric, hyphens, dots; typical Linux interface names)
        if ! echo "$HA_VIP_INTERFACE" | grep -qE '^[a-zA-Z0-9._-]+$'; then
            log_error "--ha-interface contains invalid characters (got: $HA_VIP_INTERFACE)"
            exit 1
        fi
        # Auto-set --control-plane-endpoint for init
        if [ "$ACTION" = "init" ] && [ -z "$KUBEADM_CP_ENDPOINT" ]; then
            if _is_ipv6 "$HA_VIP_ADDRESS"; then
                KUBEADM_CP_ENDPOINT="[${HA_VIP_ADDRESS}]:6443"
            else
                KUBEADM_CP_ENDPOINT="${HA_VIP_ADDRESS}:6443"
            fi
        fi
    fi
}
