#!/bin/sh

# === Cluster Join (join subcommand) ===
# Depends on: lib/components/kube_vip.sh (deploy_kube_vip, _verify_kube_vip_kubeconfig, _configure_kubectl)

# Join node to cluster
join_cluster() {
    log_info "Joining node to cluster..."

    # Deploy kube-vip on additional control-plane nodes
    # Skip VIP pre-add to avoid conflicts with the existing VIP leader
    if [ "${JOIN_AS_CONTROL_PLANE:-false}" = true ] && [ -n "$HA_VIP_ADDRESS" ]; then
        deploy_kube_vip --skip-vip-preadd || return 1
    fi

    _configure_kubelet_node_ip

    set -- "$JOIN_ADDRESS" --token "$JOIN_TOKEN" --discovery-token-ca-cert-hash "$DISCOVERY_TOKEN_HASH"
    if [ "$CRI" != "containerd" ]; then
        local cri_socket
        cri_socket=$(get_cri_socket)
        set -- "$@" --cri-socket "$cri_socket"
    fi

    # HA cluster: join as control-plane node
    if [ "${JOIN_AS_CONTROL_PLANE:-false}" = true ]; then
        set -- "$@" --control-plane --certificate-key "$CERTIFICATE_KEY"
    fi
    if [ -n "${KUBEADM_PATCHES_DIR:-}" ]; then
        set -- "$@" --patches "$KUBEADM_PATCHES_DIR"
    fi

    local join_exit=0
    # shellcheck disable=SC2046 # intentional word splitting
    kubeadm join "$@" $(_kubeadm_preflight_ignore_args) || join_exit=$?

    if [ "$join_exit" -ne 0 ]; then
        log_error "kubeadm join failed (exit code: $join_exit)"
        return "$join_exit"
    fi

    # Verify kube-vip kubeconfig exists for control-plane join
    if [ "${JOIN_AS_CONTROL_PLANE:-false}" = true ] && [ -n "$HA_VIP_ADDRESS" ]; then
        _verify_kube_vip_kubeconfig
    fi

    # Configure kubectl for control-plane join
    if [ "${JOIN_AS_CONTROL_PLANE:-false}" = true ]; then
        _configure_kubectl
        log_info "Control-plane node has joined the cluster!"
    else
        log_info "Worker node has joined the cluster!"
    fi
}
