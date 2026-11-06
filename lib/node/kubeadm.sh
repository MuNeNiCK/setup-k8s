#!/bin/sh

# Kubeadm configuration generation helpers.
# Used by commands/init.sh (initialize_cluster).

# Helper: Auto-detect kubeadm and KubeProxy API versions from kubeadm defaults
# Caches output to avoid duplicate subprocess calls.
_KUBEADM_DEFAULTS_CACHE=""
_kubeadm_defaults() {
    if [ -z "$_KUBEADM_DEFAULTS_CACHE" ]; then
        _KUBEADM_DEFAULTS_CACHE=$(kubeadm config print init-defaults 2>/dev/null) || true
    fi
    echo "$_KUBEADM_DEFAULTS_CACHE"
}

_kubeadm_api_version() {
    local api_ver
    api_ver=$(_kubeadm_defaults | awk '/^apiVersion: kubeadm\.k8s\.io\// {print $2; exit}')
    if [ -z "$api_ver" ]; then
        log_warn "Could not detect kubeadm API version, using default: kubeadm.k8s.io/v1beta3"
        api_ver="kubeadm.k8s.io/v1beta3"
    fi
    echo "$api_ver"
}

_kubeproxy_api_version() {
    local api_ver
    api_ver=$(_kubeadm_defaults | awk '/^apiVersion: kubeproxy\.config\.k8s\.io\// {print $2; exit}')
    if [ -z "$api_ver" ]; then
        log_warn "Could not detect KubeProxy API version, using default: kubeproxy.config.k8s.io/v1alpha1"
        api_ver="kubeproxy.config.k8s.io/v1alpha1"
    fi
    echo "$api_ver"
}

_kubelet_api_version() {
    local api_ver
    api_ver=$(_kubeadm_defaults | awk '/^apiVersion: kubelet\.config\.k8s\.io\// {print $2; exit}')
    if [ -z "$api_ver" ]; then
        api_ver="kubelet.config.k8s.io/v1beta1"
    fi
    echo "$api_ver"
}

_yaml_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"
}

# Helper: Generate kubeadm configuration
generate_kubeadm_config() {
    local config_file
    config_file=$(mktemp /tmp/kubeadm-config-XXXXXX)
    chmod 600 "$config_file"

    log_info "Generating kubeadm configuration..."

    # Use pre-parsed kubeadm variables (set by parse_setup_args / validate_ha_args)
    local POD_CIDR="$KUBEADM_POD_CIDR"
    local SERVICE_CIDR="$KUBEADM_SERVICE_CIDR"
    local API_ADDR="$KUBEADM_API_ADDR"
    local CP_ENDPOINT="$KUBEADM_CP_ENDPOINT"

    # Auto-detect API versions
    local kubeadm_api kubeproxy_api
    kubeadm_api=$(_kubeadm_api_version)
    kubeproxy_api=$(_kubeproxy_api_version)

    # InitConfiguration
    cat > "$config_file" <<EOF
apiVersion: $kubeadm_api
kind: InitConfiguration
EOF

    # localAPIEndpoint under InitConfiguration (not ClusterConfiguration)
    if [ -n "$API_ADDR" ]; then
        cat >> "$config_file" <<EOF
localAPIEndpoint:
  advertiseAddress: $(_yaml_quote "$API_ADDR")
EOF
    fi

    # Add CRI socket if not using default containerd
    if [ "$CRI" != "containerd" ]; then
        local cri_socket
        cri_socket=$(get_cri_socket)
        cat >> "$config_file" <<EOF
nodeRegistration:
  criSocket: $cri_socket
EOF
    fi

    # ClusterConfiguration
    cat >> "$config_file" <<EOF
---
apiVersion: $kubeadm_api
kind: ClusterConfiguration
EOF

    if [ -n "$POD_CIDR" ] || [ -n "$SERVICE_CIDR" ]; then
        echo "networking:" >> "$config_file"
        [ -n "$POD_CIDR" ]     && echo "  podSubnet: $(_yaml_quote "$POD_CIDR")" >> "$config_file"
        [ -n "$SERVICE_CIDR" ] && echo "  serviceSubnet: $(_yaml_quote "$SERVICE_CIDR")" >> "$config_file"
    fi

    if [ -n "$CP_ENDPOINT" ]; then
        echo "controlPlaneEndpoint: $(_yaml_quote "$CP_ENDPOINT")" >> "$config_file"
    fi

    # Add extra SANs for API server certificate (must be in same ClusterConfiguration document)
    if [ -n "${API_SERVER_EXTRA_SANS:-}" ]; then
        echo "apiServer:" >> "$config_file"
        echo "  certSANs:" >> "$config_file"
        _emit_san() { echo "  - $(_yaml_quote "$1")" >> "$config_file"; }
        _csv_for_each "$API_SERVER_EXTRA_SANS" _emit_san
    fi

    # Add KubeProxyConfiguration for non-default proxy modes
    if [ "$PROXY_MODE" = "ipvs" ]; then
        cat >> "$config_file" <<EOF
---
apiVersion: $kubeproxy_api
kind: KubeProxyConfiguration
mode: ipvs
ipvs:
  scheduler: "rr"
  strictARP: true
EOF
    elif [ "$PROXY_MODE" = "nftables" ]; then
        cat >> "$config_file" <<EOF
---
apiVersion: $kubeproxy_api
kind: KubeProxyConfiguration
mode: nftables
EOF
    fi

    if [ "$SWAP_ENABLED" = true ]; then
        local kubelet_api
        kubelet_api=$(_kubelet_api_version)
        cat >> "$config_file" <<EOF
---
apiVersion: $kubelet_api
kind: KubeletConfiguration
failSwapOn: false
memorySwap:
  swapBehavior: LimitedSwap
EOF
    fi

    # Append kubeadm config patch file if specified
    if [ -n "${KUBEADM_CONFIG_PATCH:-}" ] && [ -f "$KUBEADM_CONFIG_PATCH" ]; then
        log_info "Appending kubeadm config patch from: $KUBEADM_CONFIG_PATCH"
        printf '\n---\n' >> "$config_file"
        cat "$KUBEADM_CONFIG_PATCH" >> "$config_file"
    fi

    echo "$config_file"
}

# ============================================================
# Join command parsing
# ============================================================

# Join token extraction from a control-plane node.
# Used by deploy orchestration to obtain kubeadm join credentials.

# Extract join information from the first control-plane node
# Sets: _JOIN_COMMAND, _JOIN_TOKEN, _JOIN_ADDR, _JOIN_HASH, _CERT_KEY
_extract_join_info() {
    local user="$1" host="$2"

    log_info "[$host] Extracting join information..."

    # Get join command (use sudo -n when not root for fail-fast on missing NOPASSWD)
    local sudo_pfx; sudo_pfx=$(_sudo_prefix "$user")
    local attempt=1 max_attempts=3
    _JOIN_COMMAND=""
    while [ "$attempt" -le "$max_attempts" ]; do
        _JOIN_COMMAND=$(_deploy_ssh "$user" "$host" "${sudo_pfx}kubeadm token create --print-join-command") && break
        log_warn "[$host] Join command extraction attempt $attempt/$max_attempts failed, retrying in ${attempt}s..."
        sleep "$attempt"
        attempt=$((attempt + 1))
    done
    if [ -z "$_JOIN_COMMAND" ]; then
        log_error "[$host] Failed to extract join command after $max_attempts attempts"
        return 1
    fi
    log_debug "Join command: $_JOIN_COMMAND"

    # Parse token, address, and hash from join command using word-based splitting
    # Expected format: kubeadm join <addr> --token <token> --discovery-token-ca-cert-hash <hash>
    _JOIN_ADDR="" _JOIN_TOKEN="" _JOIN_HASH=""
    # shellcheck disable=SC2086 # intentional word splitting of join command
    set -- $_JOIN_COMMAND
    while [ $# -gt 0 ]; do
        case "$1" in
            join)
                # Next word is the address (if not a flag)
                if [ $# -ge 2 ]; then
                    case "$2" in
                        -*) ;;
                        *) _JOIN_ADDR="$2" ;;
                    esac
                fi
                ;;
            --token)
                [ $# -ge 2 ] && _JOIN_TOKEN="$2"
                ;;
            --discovery-token-ca-cert-hash)
                [ $# -ge 2 ] && _JOIN_HASH="$2"
                ;;
        esac
        shift
    done

    if [ -z "$_JOIN_TOKEN" ] || [ -z "$_JOIN_ADDR" ] || [ -z "$_JOIN_HASH" ]; then
        log_error "[$host] Failed to parse join command components"
        log_error "  Join command was: $_JOIN_COMMAND"
        log_error "  Parsed: addr='$_JOIN_ADDR' token='$_JOIN_TOKEN' hash='$_JOIN_HASH'"
        return 1
    fi

    # Validate extracted values
    if ! _validate_join_token_format "$_JOIN_TOKEN" "[$host] Join token"; then
        return 1
    fi
    if ! _validate_discovery_hash_format "$_JOIN_HASH" "[$host] Discovery token hash"; then
        return 1
    fi

    # For HA: get certificate key
    _CERT_KEY=""
    local has_ha_vip=false
    if [ -n "$DEPLOY_PASSTHROUGH_ARGS" ]; then
        local _chk_arg
        while IFS= read -r _chk_arg; do
            if [ "$_chk_arg" = "--ha-vip" ]; then
                has_ha_vip=true
                break
            fi
        done <<EOF
$DEPLOY_PASSTHROUGH_ARGS
EOF
    fi

    if [ "$has_ha_vip" = true ]; then
        log_info "[$host] Uploading certificates for HA join..."
        local cert_output
        if ! cert_output=$(_deploy_ssh "$user" "$host" "${sudo_pfx}kubeadm init phase upload-certs --upload-certs"); then
            log_error "[$host] kubeadm upload-certs failed"
            return 1
        fi
        _CERT_KEY=$(echo "$cert_output" | tail -1)
        if ! echo "$_CERT_KEY" | grep -qE '^[a-f0-9]{64}$'; then
            log_error "[$host] Invalid certificate key format (expected 64 hex chars, got: '$_CERT_KEY')"
            return 1
        fi
        log_debug "Certificate key: $_CERT_KEY"
    fi

    log_info "[$host] Join info extracted successfully"
    return 0
}
