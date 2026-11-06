#!/bin/sh

# Install proxy-mode-specific packages (IPVS or nftables).
# Usage: install_proxy_mode_packages <install_cmd...>
#   install_cmd: the package install command prefix (e.g., "apt-get install -y")
# Automatically detects PROXY_MODE and installs the right packages.
install_proxy_mode_packages() {
    if [ "$PROXY_MODE" = "ipvs" ]; then
        log_info "Installing IPVS packages for IPVS proxy mode..."
        if ! "$@" ipvsadm ipset; then
            log_error "Failed to install IPVS packages (ipvsadm, ipset)"
            return 1
        fi
    elif [ "$PROXY_MODE" = "nftables" ]; then
        log_info "Installing nftables package for nftables proxy mode..."
        if ! "$@" nftables; then
            log_error "Failed to install nftables package"
            return 1
        fi
    fi
}

# Enable kernel modules
enable_kernel_modules() {
    log_info "Enabling required kernel modules..."

    # Build the full module list, then write once
    local modules="overlay
br_netfilter"

    if [ "$PROXY_MODE" = "ipvs" ]; then
        log_info "Enabling IPVS kernel modules..."
        modules="${modules}
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack"
    elif [ "$PROXY_MODE" = "nftables" ]; then
        log_info "Enabling nftables kernel modules..."
        modules="${modules}
nf_tables
nf_tables_ipv4
nf_tables_ipv6
nft_chain_nat_ipv4
nft_chain_nat_ipv6
nf_nat
nf_conntrack"
    fi

    echo "$modules" > /etc/modules-load.d/k8s.conf

    # Load required baseline modules (fail fast)
    for mod in overlay br_netfilter; do
        if ! modprobe "$mod"; then
            log_error "Failed to load required kernel module: $mod"
            return 1
        fi
    done

    # Load optional mode-specific modules (non-fatal: may be built-in; availability checks validate later)
    echo "$modules" | while IFS= read -r mod; do
        case "$mod" in
            ""|overlay|br_netfilter) continue ;;
        esac
        modprobe "$mod" || true
    done
}

# Configure network settings
configure_network_settings() {
    log_info "Adjusting network settings..."
    cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv6.conf.all.forwarding        = 1
EOF

    sysctl -p /etc/sysctl.d/k8s.conf
}

# Reset K8s-related chains for a single iptables family (iptables or ip6tables)
_reset_iptables_family() {
    local cmd="$1"
    local k8s_chain_prefixes="KUBE- FLANNEL- CNI- CILIUM_ WEAVE-"
    for table in filter nat mangle; do
        local rules
        if ! rules=$("$cmd" -t "$table" -S 2>&1); then
            log_warn "Could not read $cmd table '$table': $rules"
            continue
        fi
        for prefix in $k8s_chain_prefixes; do
            echo "$rules" | sed -n "s/.*-j \(${prefix}[^ ]*\).*/\1/p" | sort -u | while read -r chain; do
                "$cmd" -t "$table" -D FORWARD -j "$chain" 2>/dev/null || true
                "$cmd" -t "$table" -D INPUT -j "$chain" 2>/dev/null || true
                "$cmd" -t "$table" -D OUTPUT -j "$chain" 2>/dev/null || true
                "$cmd" -t "$table" -D PREROUTING -j "$chain" 2>/dev/null || true
                "$cmd" -t "$table" -D POSTROUTING -j "$chain" 2>/dev/null || true
            done
            echo "$rules" | awk "/^-N ${prefix}/"'{print $2}' | while read -r chain; do
                "$cmd" -t "$table" -F "$chain" 2>/dev/null || true
                "$cmd" -t "$table" -X "$chain" 2>/dev/null || true
            done
        done
    done
}

# Reset K8s-related iptables rules (selective cleanup to avoid flushing unrelated rules)
reset_iptables() {
    log_info "Resetting K8s-related iptables rules..."
    if command -v iptables >/dev/null 2>&1; then
        _reset_iptables_family iptables
    else
        log_warn "iptables command not found, skipping iptables reset"
    fi

    if command -v ip6tables >/dev/null 2>&1; then
        log_info "Resetting K8s-related ip6tables rules..."
        _reset_iptables_family ip6tables
    fi

    # Reset IPVS rules if ipvsadm is available
    if command -v ipvsadm >/dev/null 2>&1; then
        log_info "Resetting IPVS rules..."
        ipvsadm -C || true
    fi

    # Reset K8s-related nftables tables if nft is available (avoid flushing all rules)
    if command -v nft >/dev/null 2>&1; then
        log_info "Resetting K8s-related nftables tables..."
        local _nft_tables _nft_err
        if _nft_tables=$(nft list tables 2>&1); then
            echo "$_nft_tables" | awk '/kube-proxy|kubernetes/ {print $2, $3}' | while read -r family name; do
                if ! _nft_err=$(nft delete table "$family" "$name" 2>&1); then
                    log_warn "Failed to delete nft table $family $name: $_nft_err"
                fi
            done
        else
            log_warn "Could not list nft tables: $_nft_tables"
        fi
    fi
}

# Check IPVS availability
check_ipvs_availability() {
    local ipvs_available=true

    log_info "Checking IPVS availability..."

    # Check if IPVS modules can be loaded
    if ! modprobe -n ip_vs >/dev/null 2>&1; then
        log_warn "IPVS kernel module not available"
        ipvs_available=false
    fi

    # Check if ipvsadm is installed
    if ! command -v ipvsadm >/dev/null 2>&1; then
        log_warn "ipvsadm command not found"
        ipvs_available=false
    fi

    # Check if ipset is installed
    if ! command -v ipset >/dev/null 2>&1; then
        log_warn "ipset command not found"
        ipvs_available=false
    fi

    if [ "$ipvs_available" = false ]; then
        log_error "IPVS mode requested but IPVS prerequisites are not met"
        log_error "Please ensure ipvsadm and ipset are installed and IPVS kernel modules are available"
        return 1
    fi

    return 0
}

# Check nftables availability
check_nftables_availability() {
    local nftables_available=true

    log_info "Checking nftables availability..."

    # Note if iptables-nft is being used (common on Arch with CRI-O)
    if command -v iptables >/dev/null 2>&1 && iptables --version 2>/dev/null | grep -q nf_tables; then
        log_info "iptables-nft detected (iptables using nftables backend)"
    fi

    # Check if nftables modules can be loaded
    if ! modprobe -n nf_tables >/dev/null 2>&1; then
        log_warn "nftables kernel module not available"
        nftables_available=false
    fi

    # Check if nft command is installed
    if ! command -v nft >/dev/null 2>&1; then
        log_warn "nft command not found"
        nftables_available=false
    fi

    # Check kernel version (nftables requires >= 3.13, recommended >= 4.14)
    local kernel_major kernel_minor
    kernel_major=$(uname -r | cut -d. -f1)
    kernel_minor=$(uname -r | cut -d. -f2)
    if [ "$kernel_major" -lt 3 ] || { [ "$kernel_major" -eq 3 ] && [ "$kernel_minor" -lt 13 ]; }; then
        log_warn "Kernel version too old for nftables (requires >= 3.13)"
        nftables_available=false
    elif [ "$kernel_major" -lt 4 ] || { [ "$kernel_major" -eq 4 ] && [ "$kernel_minor" -lt 14 ]; }; then
        log_warn "Kernel version ${kernel_major}.${kernel_minor} may have limited nftables support (>= 4.14 recommended)"
    fi

    if [ "$nftables_available" = false ]; then
        log_error "nftables mode requested but prerequisites are not met"
        log_error "Please ensure nftables package is installed and kernel supports nftables"
        return 1
    fi

    return 0
}

# Clean up CNI configurations
cleanup_cni() {
    log_info "Removing CNI configurations..."
    rm -rf /etc/cni/net.d/*
    rm -rf /var/lib/cni/
}

# Remove kernel module and sysctl configurations
cleanup_network_configs() {
    log_info "Removing Kubernetes kernel module and sysctl configurations..."
    rm -f /etc/modules-load.d/k8s.conf
    rm -f /etc/sysctl.d/k8s.conf
}

# Remove crictl configuration
cleanup_crictl_config() {
    if [ -f /etc/crictl.yaml ]; then
        log_info "Removing crictl configuration..."
        rm -f /etc/crictl.yaml
    fi
}
