#!/bin/sh

# Shell completion setup for Kubernetes tools

# Detect user's shell
detect_user_shell() {
    local user_shell=""

    # Check SHELL environment variable first
    if [ -n "${SHELL:-}" ]; then
        user_shell=$(basename "$SHELL")
    fi

    # Check /etc/passwd for the user's default shell
    if [ -z "$user_shell" ] && [ -n "${SUDO_USER:-}" ]; then
        local _shell_path
        _shell_path=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f7) || true
        [ -n "$_shell_path" ] && user_shell=$(basename "$_shell_path")
    elif [ -z "$user_shell" ]; then
        local _shell_path
        _shell_path=$(getent passwd "${USER:-root}" 2>/dev/null | cut -d: -f7) || true
        [ -n "$_shell_path" ] && user_shell=$(basename "$_shell_path")
    fi

    # Default to bash if detection fails
    if [ -z "$user_shell" ]; then
        user_shell="bash"
    fi

    echo "$user_shell"
}

# Generic: setup tool completion for a given shell
# Usage: _setup_tool_completion <tool> <shell> [alias]
_setup_tool_completion() {
    local tool="$1"
    local shell_type="$2"
    local alias_name="${3:-}"

    if ! command -v "$tool" >/dev/null 2>&1; then
        log_info "$tool not found, skipping completion setup"
        return 1
    fi

    log_info "Setting up $tool completion for $shell_type..."

    case "$shell_type" in
        bash)
            # System-wide bash completion
            if [ -d /etc/bash_completion.d ]; then
                if ! "$tool" completion bash > "/etc/bash_completion.d/$tool"; then
                    log_warn "$tool bash completion setup failed"
                    return 1
                fi
                log_info "$tool bash completion installed to /etc/bash_completion.d/"
            fi

            # User-specific alias (completion is loaded system-wide above)
            if [ -n "$alias_name" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
                local user_home
                user_home=$(get_user_home "$SUDO_USER")
                if [ -f "$user_home/.bashrc" ]; then
                    if ! grep -q "alias ${alias_name}=${tool}" "$user_home/.bashrc"; then
                        {
                            echo ""
                            echo "# $tool alias"
                            echo "alias ${alias_name}=${tool}"
                            echo "complete -o default -F __start_${tool} ${alias_name}"
                        } >> "$user_home/.bashrc"
                        chown "${SUDO_USER}:$(id -gn "$SUDO_USER")" "$user_home/.bashrc"
                        log_info "$tool bash alias added to $user_home/.bashrc"
                    fi
                fi
            fi
            ;;

        zsh)
            # System-wide zsh completion
            local zsh_dir=""
            [ -d /usr/share/zsh/site-functions ] && zsh_dir="/usr/share/zsh/site-functions"
            [ -d /usr/local/share/zsh/site-functions ] && zsh_dir="/usr/local/share/zsh/site-functions"

            if [ -n "$zsh_dir" ]; then
                if ! "$tool" completion zsh > "${zsh_dir}/_${tool}"; then
                    log_warn "$tool zsh completion setup failed"
                    return 1
                fi
                log_info "$tool zsh completion installed to ${zsh_dir}/"
            fi

            # User-specific alias (completion is loaded system-wide above)
            if [ -n "$alias_name" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
                local user_home
                user_home=$(get_user_home "$SUDO_USER")
                if [ -f "$user_home/.zshrc" ]; then
                    if ! grep -q "alias ${alias_name}=${tool}" "$user_home/.zshrc"; then
                        {
                            echo ""
                            echo "# $tool alias"
                            echo "alias ${alias_name}=${tool}"
                            echo "compdef ${alias_name}=${tool}"
                        } >> "$user_home/.zshrc"
                        chown "${SUDO_USER}:$(id -gn "$SUDO_USER")" "$user_home/.zshrc"
                        log_info "$tool zsh alias added to $user_home/.zshrc"
                    fi
                fi
            fi
            ;;

        fish)
            if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
                local user_home
                user_home=$(get_user_home "$SUDO_USER")
                local fish_dir="$user_home/.config/fish/completions"

                if [ ! -d "$fish_dir" ]; then
                    mkdir -p "$fish_dir"
                    chown -R "${SUDO_USER}:$(id -gn "$SUDO_USER")" "$user_home/.config"
                fi

                if ! "$tool" completion fish > "$fish_dir/${tool}.fish"; then
                    log_warn "$tool fish completion setup failed"
                    return 1
                fi
                chown "${SUDO_USER}:$(id -gn "$SUDO_USER")" "$fish_dir/${tool}.fish"
                log_info "$tool fish completion installed to $fish_dir/"

                # Add alias if config.fish exists
                if [ -n "$alias_name" ] && [ -f "$user_home/.config/fish/config.fish" ]; then
                    if ! grep -q "alias ${alias_name} ${tool}" "$user_home/.config/fish/config.fish"; then
                        {
                            echo ""
                            echo "# $tool alias"
                            echo "alias ${alias_name} ${tool}"
                        } >> "$user_home/.config/fish/config.fish"
                        chown "${SUDO_USER}:$(id -gn "$SUDO_USER")" "$user_home/.config/fish/config.fish"
                    fi
                fi
            fi
            ;;

        *)
            log_warn "Unsupported shell: $shell_type"
            return 1
            ;;
    esac

    return 0
}

# Generic: cleanup tool completion
# Usage: _cleanup_tool_completion <tool> [alias]
_cleanup_tool_completion() {
    local tool="$1"
    local alias_name="${2:-}"

    log_info "Removing $tool completions..."

    # Remove system-wide completions
    rm -f "/etc/bash_completion.d/$tool"
    rm -f "/usr/share/zsh/site-functions/_${tool}"
    rm -f "/usr/local/share/zsh/site-functions/_${tool}"

    # Remove from user configs
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        local user_home
        user_home=$(get_user_home "$SUDO_USER")

        # Clean bashrc
        if [ -f "$user_home/.bashrc" ]; then
            sed -i "/# ${tool} alias/d" "$user_home/.bashrc"
            [ -n "$alias_name" ] && sed -i "/alias ${alias_name}=${tool}/d" "$user_home/.bashrc"
            [ -n "$alias_name" ] && sed -i "/complete -o default -F __start_${tool} ${alias_name}/d" "$user_home/.bashrc"
        fi

        # Clean zshrc
        if [ -f "$user_home/.zshrc" ]; then
            sed -i "/# ${tool} alias/d" "$user_home/.zshrc"
            [ -n "$alias_name" ] && sed -i "/alias ${alias_name}=${tool}/d" "$user_home/.zshrc"
            [ -n "$alias_name" ] && sed -i "/compdef ${alias_name}=${tool}/d" "$user_home/.zshrc"
        fi

        # Clean fish completions
        rm -f "$user_home/.config/fish/completions/${tool}.fish"
        if [ -n "$alias_name" ] && [ -f "$user_home/.config/fish/config.fish" ]; then
            sed -i "/# ${tool} alias/d" "$user_home/.config/fish/config.fish"
            sed -i "/alias ${alias_name} ${tool}/d" "$user_home/.config/fish/config.fish"
        fi
    fi

    log_info "$tool completions removed"
}

# Main function to setup all completions
setup_kubernetes_completions() {
    log_info "Setting up Kubernetes shell completions..."

    # Detect shell(s) to configure
    local shells_to_configure

    if [ "$COMPLETION_SHELLS" = "auto" ]; then
        local detected_shell
        detected_shell=$(detect_user_shell)
        shells_to_configure="$detected_shell"
        log_info "Auto-detected shell: $detected_shell"
    else
        shells_to_configure=$(echo "$COMPLETION_SHELLS" | tr ',' ' ')
    fi

    for shell_type in $shells_to_configure; do
        shell_type=$(echo "$shell_type" | tr -d ' ')
        log_info "Configuring completions for $shell_type..."
        _setup_tool_completion kubectl "$shell_type" k || true
        _setup_tool_completion kubeadm "$shell_type" || true
        _setup_tool_completion crictl "$shell_type" || true
        _setup_tool_completion helm "$shell_type" || true
        _setup_tool_completion kustomize "$shell_type" || true
    done

    log_info "Shell completion setup completed!"
    log_info ""
    log_info "To activate completions:"
    log_info "  - For bash: source ~/.bashrc or start a new terminal"
    log_info "  - For zsh: source ~/.zshrc or start a new terminal"
    log_info "  - For fish: completions are immediately available"
    log_info ""
    log_info "Useful aliases have been configured:"
    log_info "  - 'k' for kubectl"

    return 0
}

# Function to be called from setup script
setup_k8s_shell_completion() {
    if [ "$ENABLE_COMPLETION" = true ]; then
        setup_kubernetes_completions
    else
        log_info "Shell completion setup skipped (disabled by configuration)"
    fi
}

# Main cleanup function for all Kubernetes completions
cleanup_kubernetes_completions() {
    log_info "Cleaning up Kubernetes shell completions..."
    _cleanup_tool_completion kubectl k
    _cleanup_tool_completion kubeadm
    _cleanup_tool_completion crictl
    _cleanup_tool_completion helm
    _cleanup_tool_completion kustomize
    log_info "Shell completion cleanup completed!"
}
