#!/bin/sh

# === Setup argument parsing (init/join) ===

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
                # Strict format validation: must be MAJOR.MINOR (e.g., 1.29, 1.32)
                if ! echo "$2" | grep -qE '^[0-9]+\.[0-9]+$'; then
                    log_error "--kubernetes-version must be in MAJOR.MINOR format (e.g., 1.29, 1.32), got '$2'"
                    exit 1
                fi
                # shellcheck disable=SC2034 # used by setup-k8s.sh
                K8S_VERSION="$2"
                shift 2
                ;;
            --join-token)
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
            --discovery-token-hash)
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
            --api-server-extra-sans)
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
# Kubeadm config generation helpers → lib/kubeadm.sh

# Initialize Kubernetes cluster
initialize_cluster() {
    log_info "Initializing cluster..."

    # Deploy kube-vip before kubeadm init if HA is enabled
    if [ "$HA_ENABLED" = true ]; then
        deploy_kube_vip
    fi

    _configure_kubelet_node_ip

    # Run kubeadm init, capturing exit code for rollback
    local init_exit=0
    if [ "$PROXY_MODE" != "iptables" ] || [ -n "$KUBEADM_POD_CIDR" ] || \
       [ -n "$KUBEADM_SERVICE_CIDR" ] || [ -n "$KUBEADM_API_ADDR" ] || \
       [ -n "$KUBEADM_CP_ENDPOINT" ] || [ "$SWAP_ENABLED" = true ] || \
       [ -n "${API_SERVER_EXTRA_SANS:-}" ] || [ -n "${KUBEADM_CONFIG_PATCH:-}" ]; then
        local CONFIG_FILE
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
    else
        if [ "$CRI" != "containerd" ]; then
            local cri_socket
            cri_socket=$(get_cri_socket)
            # shellcheck disable=SC2046 # intentional word splitting
            kubeadm init --cri-socket "$cri_socket" $(_kubeadm_preflight_ignore_args) || init_exit=$?
        else
            # shellcheck disable=SC2046 # intentional word splitting
            kubeadm init $(_kubeadm_preflight_ignore_args) || init_exit=$?
        fi
    fi

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
            log_warn "kubeadm upload-certs failed (cluster init succeeded)"
            log_warn "You can manually run: kubeadm init phase upload-certs --upload-certs"
            return 0
        fi
        cert_key=$(echo "$cert_output" | tail -1)
        if ! echo "$cert_key" | grep -qE '^[a-f0-9]{64}$'; then
            log_error "Invalid certificate key format (expected 64 hex chars, got: '$cert_key')"
            return 1
        fi
        log_info "Certificate key: $cert_key"
        log_info ""
        log_info "To join additional control-plane nodes, run:"
        log_info "  setup-k8s.sh join --control-plane --certificate-key $cert_key \\"
        log_info "    --ha-vip ${HA_VIP_ADDRESS} \\"
        log_info "    --join-token <token> --join-address <address> --discovery-token-hash <hash>"
        log_info "================================================="
    fi

    log_info "Cluster initialization complete!"
    log_info "Next steps:"
    log_info "1. Install a CNI plugin"
    log_info "2. For single-node clusters, remove the taint with:"
    log_info "   kubectl taint nodes --all node-role.kubernetes.io/control-plane-"
}
