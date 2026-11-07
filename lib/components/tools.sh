#!/bin/sh

# Helm and Kustomize, installed as pinned release binaries with sha256
# verification (HELM_VERSION, KUSTOMIZE_VERSION).

# Download a release tarball, verify it, and install one binary from it to
# /usr/local/bin.
# Usage: _install_tool_from_tarball <name> <url> <checksum_url> <checksum_filename> <path_in_tarball>
_install_tool_from_tarball() {
    local name="$1" url="$2" checksum_url="$3" checksum_name="$4" member="$5" tmp dir
    tmp=$(mktemp /tmp/"${name}"-XXXXXX)
    dir=$(mktemp -d /tmp/"${name}"-extract-XXXXXX)
    if ! _download_with_checksum "$url" "$tmp" "$checksum_url" "$checksum_name"; then
        rm -rf "$tmp" "$dir"
        return 1
    fi
    if ! tar -xzf "$tmp" -C "$dir" "$member"; then
        log_error "Failed to extract ${member} from ${url}"
        rm -rf "$tmp" "$dir"
        return 1
    fi
    if ! install -m 0755 "$dir/$member" "/usr/local/bin/${name}"; then
        log_error "Failed to install /usr/local/bin/${name}"
        rm -rf "$tmp" "$dir"
        return 1
    fi
    rm -rf "$tmp" "$dir"
    log_info "${name} installed to /usr/local/bin/${name}"
}

# Install Helm
install_helm() {
    local arch file
    arch=$(_detect_arch)
    file="helm-v${HELM_VERSION}-linux-${arch}.tar.gz"
    log_info "Installing Helm v${HELM_VERSION}..."
    _install_tool_from_tarball helm "https://get.helm.sh/${file}" \
        "https://get.helm.sh/${file}.sha256sum" "$file" "linux-${arch}/helm"
}

# Main function to setup Helm
setup_helm() {
    if [ "$INSTALL_HELM" != true ]; then
        log_info "Helm installation skipped (disabled by configuration)"
        return 0
    fi

    # Check if helm is already installed
    if command -v helm >/dev/null 2>&1; then
        log_info "Helm is already installed: $(helm version --short)"
        log_info "Skipping Helm installation"
    else
        # Install Helm
        if ! install_helm; then
            log_warn "Helm installation failed"
            return 1
        fi
    fi

    return 0
}

# Cleanup functions

# Remove Helm binary and configuration
cleanup_helm() {
    log_info "Removing Helm..."
    rm -f /usr/local/bin/helm

    # Remove Helm config/cache directories for relevant users
    local _helm_users="root"
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        _helm_users="root $SUDO_USER"
    fi
    for _user in $_helm_users; do
        local _home
        _home=$(get_user_home "$_user")
        rm -rf "$_home/.config/helm" "$_home/.helm" "$_home/.cache/helm"
    done

    log_info "Helm has been removed"
}

# ============================================================
# Kustomize
# ============================================================

# Install Kustomize
install_kustomize() {
    local arch file base
    arch=$(_detect_arch)
    file="kustomize_v${KUSTOMIZE_VERSION}_linux_${arch}.tar.gz"
    base="https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}"
    log_info "Installing Kustomize v${KUSTOMIZE_VERSION}..."
    _install_tool_from_tarball kustomize "${base}/${file}" "${base}/checksums.txt" "$file" kustomize
}

# Main function to setup Kustomize
setup_kustomize() {
    if [ "$INSTALL_KUSTOMIZE" != true ]; then
        log_info "Kustomize installation skipped (disabled by configuration)"
        return 0
    fi

    if command -v kustomize >/dev/null 2>&1; then
        log_info "Kustomize is already installed: $(kustomize version)"
        log_info "Skipping Kustomize installation"
    else
        if ! install_kustomize; then
            log_warn "Kustomize installation failed"
            return 1
        fi
    fi

    return 0
}

# Cleanup functions

# Remove Kustomize binary and configuration
cleanup_kustomize() {
    log_info "Removing Kustomize..."
    rm -f /usr/local/bin/kustomize

    # Remove Kustomize config/cache directories for relevant users.
    local _kustomize_users="root"
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        _kustomize_users="root $SUDO_USER"
    fi
    for _user in $_kustomize_users; do
        local _home
        _home=$(get_user_home "$_user")
        rm -rf "$_home/.config/kustomize" "$_home/.kustomize" "$_home/.cache/kustomize"
    done

    log_info "Kustomize has been removed"
}
