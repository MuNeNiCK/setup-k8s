#!/bin/sh

# Validation module: input validation for init/join arguments, CIDR, proxy mode, etc.
# SSH argument parsing/validation → lib/ssh.sh
# UI helpers (_confirm_destructive_action, _show_help_footer) → lib/helpers.sh
# Passthrough accumulation helpers → lib/ssh_args.sh

# Parse and validate --distro argument, set DISTRO_OVERRIDE.
# Usage: _parse_distro_arg "$2"
_parse_distro_arg() {
    case "$1" in
        debian|rhel|suse|arch|alpine|generic)
            # shellcheck disable=SC2034 # used by detection.sh after sourcing
            DISTRO_OVERRIDE="$1"
            ;;
        *)
            log_error "--distro must be one of: debian, rhel, suse, arch, alpine, generic (got '$1')"
            exit 1
            ;;
    esac
}

# Validate join token format: 6 lowercase alphanumeric chars, dot, 16 lowercase alphanumeric chars.
# Usage: _validate_join_token_format <token> [label]
_validate_join_token_format() {
    local token="$1" label="${2:---join-token}"
    if ! echo "$token" | grep -qE '^[a-z0-9]{6}\.[a-z0-9]{16}$'; then
        log_error "$label format is invalid (expected: [a-z0-9]{6}.[a-z0-9]{16}, got: $token)"
        return 1
    fi
}

# Validate discovery token hash format: sha256:<64 hex chars>.
# Usage: _validate_discovery_hash_format <hash> [label]
_validate_discovery_hash_format() {
    local hash="$1" label="${2:---discovery-token-hash}"
    if ! echo "$hash" | grep -qE '^sha256:[a-f0-9]{64}$'; then
        log_error "$label format is invalid (expected: sha256:<64 hex chars>, got: $hash)"
        return 1
    fi
}

# Check required arguments for join
validate_join_args() {
    if [ "$ACTION" = "join" ]; then
        if [ -z "$JOIN_TOKEN" ] || [ -z "$JOIN_ADDRESS" ] || [ -z "$DISCOVERY_TOKEN_HASH" ]; then
            log_error "join requires --join-token, --join-address, and --discovery-token-hash"
            exit 1
        fi
        if ! _validate_join_token_format "$JOIN_TOKEN" "--join-token"; then
            exit 1
        fi
        if ! _validate_discovery_hash_format "$DISCOVERY_TOKEN_HASH" "--discovery-token-hash"; then
            exit 1
        fi
        # Validate join address format: host:port (host part must be non-empty)
        if ! echo "$JOIN_ADDRESS" | grep -qE '^.+:[0-9]+$'; then
            log_error "--join-address should include a port (e.g., 192.168.1.10:6443 or [::1]:6443, got: $JOIN_ADDRESS)"
            exit 1
        fi
        local _join_port="${JOIN_ADDRESS##*:}"
        if [ "$_join_port" -lt 1 ] || [ "$_join_port" -gt 65535 ]; then
            log_error "--join-address port out of range (1-65535, got: $_join_port)"
            exit 1
        fi
        # Validate HA control-plane join args
        if [ "$JOIN_AS_CONTROL_PLANE" = true ] && [ -z "$CERTIFICATE_KEY" ]; then
            log_error "--control-plane requires --certificate-key"
            exit 1
        fi
    fi
}

# Validate CRI selection
validate_cri() {
    case "$CRI" in
        containerd|crio) ;;
        *) log_error "Unsupported CRI '$CRI'. Supported options are: containerd, crio"; exit 1 ;;
    esac
}

# Validate shell completion options
validate_completion_options() {
    if [ "$ENABLE_COMPLETION" != "true" ] && [ "$ENABLE_COMPLETION" != "false" ]; then
        log_error "--enable-completion must be 'true' or 'false'"
        exit 1
    fi

    if [ "$INSTALL_HELM" != "true" ] && [ "$INSTALL_HELM" != "false" ]; then
        log_error "--install-helm must be 'true' or 'false'"
        exit 1
    fi

    if [ "$INSTALL_KUSTOMIZE" != "true" ] && [ "$INSTALL_KUSTOMIZE" != "false" ]; then
        log_error "--install-kustomize must be 'true' or 'false'"
        exit 1
    fi

    if [ "$COMPLETION_SHELLS" != "auto" ]; then
        _validate_single_shell() {
            local shell_name
            shell_name=$(echo "$1" | tr -d ' ')
            case "$shell_name" in
                bash|zsh|fish) ;;
                *)
                    log_error "Invalid shell '$shell_name' in --completion-shells. Valid options are: bash, zsh, fish, or 'auto'"
                    exit 1
                    ;;
            esac
        }
        _csv_for_each "$COMPLETION_SHELLS" _validate_single_shell
    fi
}

# Validate proxy mode selection
validate_proxy_mode() {
    if [ "$PROXY_MODE" != "iptables" ] && [ "$PROXY_MODE" != "ipvs" ] && [ "$PROXY_MODE" != "nftables" ]; then
        log_error "Proxy mode must be 'iptables', 'ipvs', or 'nftables'"
        exit 1
    fi

    if [ "$PROXY_MODE" = "ipvs" ]; then
        local k8s_major k8s_minor
        k8s_major=$(echo "$K8S_VERSION" | cut -d. -f1)
        k8s_minor=$(echo "$K8S_VERSION" | cut -d. -f2)
        if [ "$k8s_major" -gt 1 ] || [ "$k8s_major" -eq 1 ] && [ "$k8s_minor" -ge 35 ]; then
            log_warn "ipvs proxy mode is deprecated in Kubernetes 1.35+; migrate to nftables when possible"
        fi
    fi

    if [ "$PROXY_MODE" = "nftables" ]; then
        local k8s_major k8s_minor
        k8s_major=$(echo "$K8S_VERSION" | cut -d. -f1)
        k8s_minor=$(echo "$K8S_VERSION" | cut -d. -f2)

        if [ "$k8s_major" -lt 1 ] || [ "$k8s_major" -eq 1 ] && [ "$k8s_minor" -lt 29 ]; then
            log_error "nftables proxy mode requires Kubernetes 1.29 or higher"
            log_error "Current version: $K8S_VERSION"
            log_error "Please use --kubernetes-version 1.29 or higher, or choose a different proxy mode"
            exit 1
        fi

        if [ "$k8s_major" -eq 1 ] && [ "$k8s_minor" -lt 31 ]; then
            log_warn "nftables is in alpha status in Kubernetes $K8S_VERSION (beta from 1.31+)"
        fi
    fi
}

# Validate swap enabled option (requires K8s 1.28+)
validate_swap_enabled() {
    if [ "$SWAP_ENABLED" = true ] && [ -n "$K8S_VERSION" ]; then
        local k8s_minor
        k8s_minor=$(echo "$K8S_VERSION" | cut -d. -f2)
        if [ -n "$k8s_minor" ] && [ "$k8s_minor" -lt 28 ]; then
            log_error "--swap-enabled requires Kubernetes 1.28+ (got: $K8S_VERSION)"
            exit 1
        fi
    fi
}

# Check if an address is IPv6 (contains colon)
_is_ipv6() {
    case "$1" in
        *:*) return 0 ;;
        *) return 1 ;;
    esac
}

# Validate an IPv6 address (no brackets, no CIDR prefix)
_validate_ipv6_addr() {
    local addr="$1" label="$2"
    if ! echo "$addr" | grep -qE '^[a-fA-F0-9:]+$'; then
        log_error "Invalid IPv6 address for $label: $addr"
        exit 1
    fi
}

# Validate an IPv6 CIDR (addr/prefix)
_validate_ipv6_cidr() {
    local cidr="$1" label="$2"
    local addr prefix
    addr="${cidr%/*}"
    prefix="${cidr##*/}"
    if ! echo "$addr" | grep -qE '^[a-fA-F0-9:]+$' || ! echo "$prefix" | grep -qE '^[0-9]+$'; then
        log_error "Invalid IPv6 CIDR for $label: $cidr"
        exit 1
    fi
    if [ "$prefix" -gt 128 ]; then
        log_error "IPv6 prefix length out of range for $label: $cidr (max 128)"
        exit 1
    fi
}

# Validate a single CIDR (IPv4 or IPv6)
_validate_single_cidr() {
    local cidr="$1" label="$2"
    if _is_ipv6 "${cidr%/*}"; then
        _validate_ipv6_cidr "$cidr" "$label"
    else
        # IPv4 CIDR validation
        if ! echo "$cidr" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$'; then
            log_error "Invalid CIDR format for $label: $cidr"
            log_error "Expected format: x.x.x.x/y (e.g., 192.168.0.0/16)"
            exit 1
        fi
        local o1 o2 o3 o4 prefix
        IFS='./' read -r o1 o2 o3 o4 prefix <<EOF
$cidr
EOF
        if [ "$o1" -gt 255 ] || [ "$o2" -gt 255 ] || [ "$o3" -gt 255 ] || [ "$o4" -gt 255 ] || [ "$prefix" -gt 32 ]; then
            log_error "CIDR values out of range for $label: $cidr"
            exit 1
        fi
    fi
}

# Validate CIDR format (IPv4, IPv6, or dual-stack comma-separated)
_validate_cidr() {
    local cidr="$1" label="$2"
    case "$cidr" in
        *,*)
            # Dual-stack: validate each CIDR separately
            local first="${cidr%%,*}"
            local second="${cidr#*,}"
            _validate_single_cidr "$first" "$label (first)"
            _validate_single_cidr "$second" "$label (second)"
            # Ensure one IPv4 + one IPv6
            local first_is_v6=false second_is_v6=false
            _is_ipv6 "${first%/*}" && first_is_v6=true
            _is_ipv6 "${second%/*}" && second_is_v6=true
            if [ "$first_is_v6" = "$second_is_v6" ]; then
                log_error "Dual-stack $label must have one IPv4 and one IPv6 CIDR (got: $cidr)"
                exit 1
            fi
            ;;
        *)
            _validate_single_cidr "$cidr" "$label"
            ;;
    esac
}

# Validate HA arguments
validate_ha_args() {
    if [ "$HA_ENABLED" = true ]; then
        if [ "$ACTION" != "init" ]; then
            log_error "--ha is only valid with the 'init' subcommand"
            exit 1
        fi
        if [ -z "$HA_VIP_ADDRESS" ]; then
            log_error "--ha requires --ha-vip ADDRESS"
            exit 1
        fi
    fi

    # On init, --ha-vip requires --ha (otherwise kube-vip is not deployed)
    if [ -n "$HA_VIP_ADDRESS" ] && [ "$ACTION" = "init" ] && [ "$HA_ENABLED" = false ]; then
        log_error "--ha-vip with init requires --ha flag"
        exit 1
    fi

    # VIP address applies to both init --ha and join --control-plane
    if [ -n "$HA_VIP_ADDRESS" ]; then
        if _is_ipv6 "$HA_VIP_ADDRESS"; then
            # Validate IPv6 VIP address
            _validate_ipv6_addr "$HA_VIP_ADDRESS" "--ha-vip"
        else
            # Validate IPv4 VIP address
            if ! echo "$HA_VIP_ADDRESS" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
                log_error "--ha-vip must be a valid IPv4 address (got: $HA_VIP_ADDRESS)"
                exit 1
            fi
            local _vo1 _vo2 _vo3 _vo4
            IFS='.' read -r _vo1 _vo2 _vo3 _vo4 <<EOF
$HA_VIP_ADDRESS
EOF
            if [ "$_vo1" -gt 255 ] || [ "$_vo2" -gt 255 ] || [ "$_vo3" -gt 255 ] || [ "$_vo4" -gt 255 ]; then
                log_error "--ha-vip octets out of range (got: $HA_VIP_ADDRESS)"
                exit 1
            fi
        fi
        # On join, --ha-vip requires --control-plane
        if [ "$ACTION" = "join" ] && [ "$JOIN_AS_CONTROL_PLANE" != true ]; then
            log_error "--ha-vip on join requires --control-plane"
            exit 1
        fi
        # Auto-detect interface if not specified
        if [ -z "$HA_VIP_INTERFACE" ]; then
            local _iproute_out
            if _is_ipv6 "$HA_VIP_ADDRESS"; then
                # IPv6: use ip -6 route get
                if ! _iproute_out=$(ip -6 route get ::1 2>&1); then
                    log_error "Could not auto-detect network interface. Please specify --ha-interface"
                    [ -n "$_iproute_out" ] && log_error "  ip route error: $_iproute_out"
                    exit 1
                fi
                HA_VIP_INTERFACE=$(echo "$_iproute_out" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
            else
                # IPv4: use ip route get
                if ! _iproute_out=$(ip route get 1 2>&1); then
                    log_error "Could not auto-detect network interface. Please specify --ha-interface"
                    [ -n "$_iproute_out" ] && log_error "  ip route error: $_iproute_out"
                    exit 1
                fi
                HA_VIP_INTERFACE=$(echo "$_iproute_out" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
            fi
            if [ -z "$HA_VIP_INTERFACE" ]; then
                log_error "Could not auto-detect network interface. Please specify --ha-interface"
                exit 1
            fi
        fi
        # Validate interface name (alphanumeric, hyphens, dots; typical Linux interface names)
        if ! echo "$HA_VIP_INTERFACE" | grep -qE '^[a-zA-Z0-9._-]+$'; then
            log_error "--ha-interface contains invalid characters (got: $HA_VIP_INTERFACE)"
            exit 1
        fi
        # Auto-set --control-plane-endpoint for init
        if [ "$ACTION" = "init" ] && [ -z "$KUBEADM_CP_ENDPOINT" ]; then
            if _is_ipv6 "$HA_VIP_ADDRESS"; then
                KUBEADM_CP_ENDPOINT="[${HA_VIP_ADDRESS}]:6443"
            else
                KUBEADM_CP_ENDPOINT="${HA_VIP_ADDRESS}:6443"
            fi
        fi
    fi
}

# Guard for options requiring a value argument
_require_value() {
    if [ $1 -lt 2 ]; then
        log_error "$2 requires a value"
        exit 1
    fi
    # Reject flag-like values (starting with -) to catch missing arguments
    case "${3:-}" in
        -*)
            log_error "$2 requires a value, got '$3' (looks like a flag)"
            exit 1
            ;;
    esac
}
