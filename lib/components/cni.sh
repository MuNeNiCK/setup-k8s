#!/bin/sh

# CNI plugins for binary installs. Package-based sources install CNI plugins
# as a dependency of kubelet or the container runtime.

# Install the CNI plugin release tarball into /opt/cni/bin.
cni_install_binaries() {
    local version="${CNI_PLUGINS_VERSION}" arch url tmp
    arch=$(_detect_arch)
    url="https://github.com/containernetworking/plugins/releases/download/v${version}/cni-plugins-linux-${arch}-v${version}.tgz"
    tmp=$(mktemp /tmp/cni-plugins-XXXXXX)
    if ! _download_with_checksum "$url" "$tmp" "${url}.sha256"; then
        rm -f "$tmp"
        return 1
    fi
    mkdir -p /opt/cni/bin
    tar -xzf "$tmp" -C /opt/cni/bin/
    rm -f "$tmp"
    log_info "CNI plugins v${version} installed to /opt/cni/bin/"
}
