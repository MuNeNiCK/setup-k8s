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
