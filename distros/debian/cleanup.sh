#!/bin/sh

# Debian/Ubuntu specific cleanup
cleanup_debian() {
    log_info "Performing Debian/Ubuntu specific cleanup..."
    
    # Remove package holds
    log_info "Removing package holds..."
    for pkg in kubeadm kubectl kubelet kubernetes-cni cri-tools; do
        apt-mark unhold "$pkg" 2>&1 || true
    done

    # Purge packages and clean up dependencies
    log_info "Purging Kubernetes and CRI packages..."
    apt-get purge -y kubeadm kubectl kubelet kubernetes-cni cri-tools ||
        log_warn "Package purge had errors (some packages may not be installed)"
    apt-get purge -y cri-o ||
        log_warn "CRI-O removal had errors (may not be installed)"
    for pkg in cri-o-runc crun conmon; do
        if dpkg -s "$pkg" >/dev/null 2>&1; then
            apt-get purge -y "$pkg" || log_warn "Failed to remove $pkg"
        fi
    done
    apt-get autoremove -y || true

    # Remove repository files
    log_info "Removing Kubernetes repository files..."
    rm -f /etc/apt/sources.list.d/kubernetes.list
    rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    rm -f /etc/apt/sources.list.d/docker.list
    rm -f /etc/apt/keyrings/docker.gpg
    rm -f /etc/apt/sources.list.d/cri-o.list
    rm -f /etc/apt/keyrings/crio-apt-keyring.gpg
    
    # Verify cleanup
    local remaining
    remaining=$(_verify_packages_removed "dpkg -s" kubeadm kubelet kubectl kubernetes-cni cri-tools cri-o)
    _verify_cleanup $remaining \
        "/etc/apt/sources.list.d/kubernetes.list" \
        "/etc/apt/keyrings/kubernetes-apt-keyring.gpg" \
        "/etc/default/kubelet"
}
