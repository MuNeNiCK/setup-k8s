#!/bin/sh

# Kubernetes node components (kubeadm, kubelet, kubectl).

# Configure kubelet node-ip if KUBELET_NODE_IP is set.
_configure_kubelet_node_ip() {
    if [ -n "${KUBELET_NODE_IP:-}" ]; then
        log_info "Setting kubelet node-ip: $KUBELET_NODE_IP"
        mkdir -p /etc/default
        echo "KUBELET_EXTRA_ARGS=\"--node-ip=${KUBELET_NODE_IP}\"" > /etc/default/kubelet
    fi
}

# Show installed versions
show_versions() {
    log_info "Installed versions:"
    log_info "  $(kubectl version --client 2>&1)"
    log_info "  $(kubeadm version 2>&1)"
}

# Enable and start kubelet service
_enable_and_start_kubelet() {
    _service_enable kubelet
    _service_start kubelet
}
