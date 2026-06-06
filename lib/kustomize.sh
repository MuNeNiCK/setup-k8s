#!/bin/sh

# Kustomize installation and setup

# Install Kustomize
install_kustomize() {
    log_info "Installing Kustomize..."

    # Download the official installer to a temporary file for inspection.
    local installer
    installer=$(mktemp /tmp/install-kustomize-XXXXXX)
    if ! curl -fsSL --retry 3 --retry-delay 2 https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh -o "$installer"; then
        log_error "Failed to download Kustomize installer"
        rm -f "$installer"
        return 1
    fi

    # Execute the installer (Kustomize's installer requires bash).
    bash "$installer" /usr/local/bin
    local rc=$?
    rm -f "$installer"
    return $rc
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
