#!/bin/sh

# Look up a Debian package version string via apt-cache madison.
# Tries exact match first (e.g. "1.33.2-"), then falls back to minor prefix ("1.33.").
# Usage: _get_debian_package_version <package> <version>
#   Prints the VERSION_STRING on stdout; returns 1 if not found.
_get_debian_package_version() {
    local pkg="$1" ver="$2"
    local madison_out vs
    madison_out=$(apt-cache madison "$pkg")
    # Try exact version match first
    vs=$(echo "$madison_out" | awk -v v="${ver}-" 'index($0, v) {print $3; exit}')
    if [ -z "$vs" ]; then
        # Fallback: minor version prefix
        local minor
        minor=$(echo "$ver" | sed 's/\.[0-9]*$//')
        vs=$(echo "$madison_out" | awk -v v="${minor}." 'index($0, v) {print $3; exit}')
    fi
    if [ -z "$vs" ]; then
        return 1
    fi
    echo "$vs"
}

# Configure Kubernetes apt repository for a given MAJOR.MINOR version.
# Usage: _configure_k8s_apt_repo <version>
_configure_k8s_apt_repo() {
    local ver="$1"
    mkdir -p /etc/apt/keyrings
    curl -fsSL --retry 3 --retry-delay 2 "https://pkgs.k8s.io/core:/stable:/v${ver}/deb/Release.key" \
        | gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    chmod 0644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${ver}/deb/ /" \
        | tee /etc/apt/sources.list.d/kubernetes.list
    apt-get update
}

# Setup Kubernetes for Debian/Ubuntu
setup_kubernetes_debian() {
    log_info "Setting up Kubernetes for Debian-based distribution..."

    _configure_k8s_apt_repo "$K8S_VERSION"
    
    # Find available version
    local VERSION_STRING
    VERSION_STRING=$(_get_debian_package_version kubeadm "$K8S_VERSION") || {
        log_error "Specified version ${K8S_VERSION} not found"
        return 1
    }
    
    # Install Kubernetes components
    apt-get install -y --allow-change-held-packages \
        kubelet="${VERSION_STRING}" kubeadm="${VERSION_STRING}" kubectl="${VERSION_STRING}" cri-tools
    apt-mark hold kubelet kubeadm kubectl cri-tools

    # Enable and start kubelet (consistent with other distros)
    _enable_and_start_kubelet
}

# Upgrade kubeadm to a specific MAJOR.MINOR.PATCH version
upgrade_kubeadm_debian() {
    local target="$1"
    local minor
    minor=$(_k8s_minor_version "$target")

    log_info "Updating Kubernetes apt repository to v${minor}..."
    _configure_k8s_apt_repo "$minor"

    # Find exact version string
    local VERSION_STRING
    VERSION_STRING=$(_get_debian_package_version kubeadm "$target") || {
        log_error "kubeadm version ${target} not found in apt repository"
        return 1
    }

    apt-mark unhold kubeadm
    apt-get install -y --allow-change-held-packages kubeadm="${VERSION_STRING}"
    apt-mark hold kubeadm
}

# Upgrade kubelet and kubectl to a specific MAJOR.MINOR.PATCH version
upgrade_kubelet_kubectl_debian() {
    local target="$1"

    local VERSION_STRING
    VERSION_STRING=$(_get_debian_package_version kubelet "$target") || {
        log_error "kubelet version ${target} not found in apt repository"
        return 1
    }

    apt-mark unhold kubelet kubectl cri-tools
    apt-get install -y --allow-change-held-packages kubelet="${VERSION_STRING}" kubectl="${VERSION_STRING}" cri-tools
    apt-mark hold kubelet kubectl cri-tools
}
