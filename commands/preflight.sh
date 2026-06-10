#!/bin/sh

# Preflight check module: verify system requirements before init/join.
# Runs all checks and reports a summary. Root required for port/module checks.
#
# === Sections ===
# 1. CLI parsing & help                     (~line 8)
# 2. Result tracking                        (~line 85)
# 3. Individual check functions              (~line 106)
# 4. Orchestration (preflight_local)         (~line 352)
# 5. Dry-run display                        (~line 401)

# --- Help ---

show_preflight_help() {
    cat <<'EOF'
Usage: setup-k8s.sh preflight [options]

Run preflight checks to verify system requirements before cluster init/join.

Options:
  --mode MODE           Check mode: init or join (default: init)
  --cri RUNTIME         Container runtime to check (containerd or crio). Default: containerd
  --proxy-mode MODE     Proxy mode to check (iptables, ipvs, or nftables). Default: iptables
  --kubernetes-version VER Target Kubernetes minor version (e.g., 1.36)
  --preflight-strict    Treat warnings as failures
  --dry-run             Show what checks would be performed
  --help, -h            Display this help message

Checks performed:
  - CPU count (>= 2 cores)
  - Memory (>= 1700 MB)
  - Disk space (warning only)
  - Required ports availability
  - Kernel modules (overlay, br_netfilter, proxy-mode specific)
  - IP forwarding
  - Container runtime installation (info only)
  - containerd v2 readiness for Kubernetes 1.36+ (warning only)
  - Swap state (warning only)
  - cgroups v2
  - SELinux state (warning only)
  - AppArmor state (info only)
  - Unattended upgrades detection (warning only)
  - Existing cluster detection (init only)
  - Network connectivity to dl.k8s.io (warning only)
EOF
    exit "${1:-0}"
}

# --- Argument parsing ---

parse_preflight_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --mode)
                _require_value $# "$1" "${2:-}"
                PREFLIGHT_MODE="$2"
                case "$PREFLIGHT_MODE" in
                    init|join) ;;
                    *)
                        log_error "Invalid --mode '$PREFLIGHT_MODE'. Valid: init, join"
                        exit 1
                        ;;
                esac
                shift 2
                ;;
            --cri)
                _require_value $# "$1" "${2:-}"
                PREFLIGHT_CRI="$2"
                shift 2
                ;;
            --proxy-mode)
                _require_value $# "$1" "${2:-}"
                PREFLIGHT_PROXY_MODE="$2"
                shift 2
                ;;
            --kubernetes-version)
                _require_value $# "$1" "${2:-}"
                PREFLIGHT_K8S_VERSION="$2"
                if ! echo "$PREFLIGHT_K8S_VERSION" | grep -qE '^[0-9]+\.[0-9]+$'; then
                    log_error "--kubernetes-version for preflight must be MAJOR.MINOR (e.g., 1.36)"
                    exit 1
                fi
                shift 2
                ;;
            --preflight-strict)
                PREFLIGHT_STRICT=true
                shift
                ;;
            --help|-h)
                show_preflight_help
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
}

# --- Result counters ---

_PREFLIGHT_PASS=0
_PREFLIGHT_FAIL=0
_PREFLIGHT_WARN=0

_preflight_record_pass() {
    _PREFLIGHT_PASS=$((_PREFLIGHT_PASS + 1))
    log_info "  [PASS] $1"
}

_preflight_record_fail() {
    _PREFLIGHT_FAIL=$((_PREFLIGHT_FAIL + 1))
    log_error "  [FAIL] $1"
}

_preflight_record_warn() {
    _PREFLIGHT_WARN=$((_PREFLIGHT_WARN + 1))
    log_warn "  [WARN] $1"
}

# --- Individual checks ---

_preflight_check_cpu() {
    local cpus
    if command -v nproc >/dev/null 2>&1; then
        cpus=$(nproc)
    elif [ -f /proc/cpuinfo ]; then
        cpus=$(grep -c '^processor' /proc/cpuinfo)
    else
        _preflight_record_warn "Cannot determine CPU count"
        return
    fi
    if [ "$cpus" -ge 2 ]; then
        _preflight_record_pass "CPU count: $cpus (>= 2)"
    else
        _preflight_record_fail "CPU count: $cpus (requires >= 2)"
    fi
}

_preflight_check_memory() {
    if [ ! -f /proc/meminfo ]; then
        _preflight_record_warn "Cannot determine memory (/proc/meminfo not found)"
        return
    fi
    local mem_kb mem_mb
    mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    mem_mb=$((mem_kb / 1024))
    if [ "$mem_mb" -ge 1700 ]; then
        _preflight_record_pass "Memory: ${mem_mb} MB (>= 1700 MB)"
    else
        _preflight_record_fail "Memory: ${mem_mb} MB (requires >= 1700 MB)"
    fi
}

_preflight_check_disk() {
    local avail_kb avail_mb
    avail_kb=$(df / 2>/dev/null | awk 'NR==2 {print $4}') || true
    if [ -z "$avail_kb" ]; then
        _preflight_record_warn "Cannot determine disk space"
        return
    fi
    avail_mb=$((avail_kb / 1024))
    if [ "$avail_mb" -ge 2048 ]; then
        _preflight_record_pass "Disk space: ${avail_mb} MB available on /"
    else
        _preflight_record_warn "Disk space: ${avail_mb} MB available on / (recommend >= 2048 MB)"
    fi
}

_preflight_check_ports() {
    local ports
    if [ "$PREFLIGHT_MODE" = "init" ]; then
        ports="6443 2379 2380 10250 10259 10257"
    else
        ports="10250"
    fi

    if ! command -v ss >/dev/null 2>&1; then
        _preflight_record_warn "ss not found, cannot check ports"
        return
    fi

    local listening all_free=true
    listening=$(ss -tlnp 2>/dev/null) || true
    for port in $ports; do
        if echo "$listening" | grep -qE ":${port}[[:space:]]"; then
            _preflight_record_fail "Port $port is already in use"
            all_free=false
        fi
    done
    if [ "$all_free" = true ]; then
        _preflight_record_pass "Required ports available ($ports)"
    fi
}

_preflight_check_kernel_modules() {
    local modules="overlay br_netfilter"

    case "$PREFLIGHT_PROXY_MODE" in
        ipvs)
            modules="$modules ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh nf_conntrack"
            ;;
        nftables)
            modules="$modules nf_tables nf_conntrack"
            ;;
    esac

    local all_ok=true
    for mod in $modules; do
        if modprobe -n "$mod" >/dev/null 2>&1; then
            :
        else
            _preflight_record_fail "Kernel module '$mod' not available"
            all_ok=false
        fi
    done
    if [ "$all_ok" = true ]; then
        _preflight_record_pass "Required kernel modules available"
    fi
}

_preflight_check_ip_forward() {
    local val
    if [ -f /proc/sys/net/ipv4/ip_forward ]; then
        val=$(cat /proc/sys/net/ipv4/ip_forward)
        if [ "$val" = "1" ]; then
            _preflight_record_pass "IPv4 forwarding is enabled"
        else
            _preflight_record_warn "IPv4 forwarding is disabled (will be enabled during setup)"
        fi
    else
        _preflight_record_warn "Cannot check ip_forward (/proc/sys/net/ipv4/ip_forward not found)"
    fi
}

_preflight_check_cri() {
    local runtime="$PREFLIGHT_CRI"
    case "$runtime" in
        containerd)
            if command -v containerd >/dev/null 2>&1; then
                _preflight_record_pass "containerd is installed"
                _preflight_check_containerd_v2_readiness
            else
                log_info "  [INFO] containerd is not installed (will be installed during setup)"
            fi
            ;;
        crio)
            if command -v crio >/dev/null 2>&1; then
                _preflight_record_pass "crio is installed"
            else
                log_info "  [INFO] crio is not installed (will be installed during setup)"
            fi
            ;;
    esac
}

_preflight_check_containerd_v2_readiness() {
    local version major
    version=$(containerd --version 2>/dev/null | awk '{print $3}' | sed 's/^v//') || version=""
    if [ -z "$version" ]; then
        _preflight_record_warn "Cannot determine containerd version; Kubernetes 1.36+ requires containerd 2.0+"
        return
    fi

    major=$(echo "$version" | cut -d. -f1)
    if ! echo "$major" | grep -qE '^[0-9]+$'; then
        _preflight_record_warn "Cannot parse containerd version '$version'; Kubernetes 1.36+ requires containerd 2.0+"
        return
    fi

    if [ "$major" -lt 2 ]; then
        if [ -n "$PREFLIGHT_K8S_VERSION" ]; then
            local k8s_minor
            k8s_minor=$(echo "$PREFLIGHT_K8S_VERSION" | cut -d. -f2)
            if [ "$k8s_minor" -ge 36 ]; then
                _preflight_record_warn "containerd ${version} detected; upgrade to containerd 2.0+ before Kubernetes ${PREFLIGHT_K8S_VERSION}"
            fi
        else
            _preflight_record_warn "containerd ${version} detected; Kubernetes 1.36+ requires containerd 2.0+"
        fi
    else
        _preflight_record_pass "containerd ${version} is ready for Kubernetes 1.36+"
    fi
}

_preflight_check_swap() {
    local swap_total
    swap_total=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null) || swap_total="0"
    if [ "$swap_total" -gt 0 ] 2>/dev/null; then
        _preflight_record_warn "Swap is enabled (${swap_total} kB). Use --swap-enabled if intentional"
    else
        _preflight_record_pass "Swap is disabled"
    fi
}

_preflight_check_cgroups() {
    if type _has_cgroupv2 >/dev/null 2>&1; then
        if _has_cgroupv2; then
            _preflight_record_pass "cgroups v2 is available"
        else
            _preflight_record_warn "cgroups v1 detected (v2 recommended, required by default for K8s >= 1.35)"
        fi
    elif [ -f /sys/fs/cgroup/cgroup.controllers ]; then
        _preflight_record_pass "cgroups v2 is available"
    else
        _preflight_record_warn "cgroups v1 detected (v2 recommended, required by default for K8s >= 1.35)"
    fi
}

_preflight_check_existing_cluster() {
    if [ "$PREFLIGHT_MODE" != "init" ]; then
        return
    fi
    if [ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]; then
        _preflight_record_fail "Existing cluster detected (/etc/kubernetes/manifests/kube-apiserver.yaml exists)"
    elif [ -f /etc/kubernetes/admin.conf ]; then
        _preflight_record_fail "Existing cluster config detected (/etc/kubernetes/admin.conf exists)"
    else
        _preflight_record_pass "No existing cluster detected"
    fi
}

_preflight_check_selinux() {
    if ! command -v getenforce >/dev/null 2>&1; then
        # SELinux not installed, nothing to check
        return
    fi
    local mode
    mode=$(getenforce 2>/dev/null) || mode="unknown"
    case "$mode" in
        Enforcing)
            _preflight_record_warn "SELinux is in Enforcing mode (may require additional configuration for K8s)"
            ;;
        Permissive)
            _preflight_record_pass "SELinux is in Permissive mode"
            ;;
        Disabled)
            _preflight_record_pass "SELinux is disabled"
            ;;
        *)
            _preflight_record_warn "Cannot determine SELinux state: $mode"
            ;;
    esac
}

_preflight_check_apparmor() {
    if [ ! -d /sys/module/apparmor ]; then
        return
    fi
    if command -v aa-status >/dev/null 2>&1; then
        local profiles
        profiles=$(aa-status --profiled 2>/dev/null) || profiles="unknown"
        log_info "  [INFO] AppArmor is active ($profiles profiles loaded)"
    else
        log_info "  [INFO] AppArmor kernel module detected (aa-status not available)"
    fi
}

_preflight_check_unattended_upgrades() {
    # Check for Debian/Ubuntu unattended-upgrades
    if command -v unattended-upgrade >/dev/null 2>&1; then
        if systemctl is-active --quiet unattended-upgrades 2>/dev/null; then
            _preflight_record_warn "unattended-upgrades service is active (may interfere with K8s package management)"
            return
        fi
    fi
    # Check for RHEL/CentOS dnf-automatic
    if systemctl is-active --quiet dnf-automatic.timer 2>/dev/null; then
        _preflight_record_warn "dnf-automatic timer is active (may interfere with K8s package management)"
        return
    fi
    # Check for SUSE transactional-update
    if systemctl is-active --quiet transactional-update.timer 2>/dev/null; then
        _preflight_record_warn "transactional-update timer is active (may interfere with K8s package management)"
        return
    fi
}

_preflight_check_connectivity() {
    if command -v curl >/dev/null 2>&1; then
        if curl -fsSL --connect-timeout 5 --max-time 10 https://dl.k8s.io/ >/dev/null 2>&1; then
            _preflight_record_pass "Network connectivity to dl.k8s.io OK"
        else
            _preflight_record_warn "Cannot reach dl.k8s.io (check network/proxy settings)"
        fi
    elif command -v wget >/dev/null 2>&1; then
        if wget -q --spider --timeout=5 https://dl.k8s.io/ 2>/dev/null; then
            _preflight_record_pass "Network connectivity to dl.k8s.io OK"
        else
            _preflight_record_warn "Cannot reach dl.k8s.io (check network/proxy settings)"
        fi
    else
        _preflight_record_warn "Neither curl nor wget found, cannot check connectivity"
    fi
}

# --- Main entry points ---

preflight_local() {
    log_info "=== Preflight Checks ==="
    log_info "Mode: $PREFLIGHT_MODE | CRI: $PREFLIGHT_CRI | Proxy mode: $PREFLIGHT_PROXY_MODE"
    [ -n "$PREFLIGHT_K8S_VERSION" ] && log_info "Target Kubernetes version: $PREFLIGHT_K8S_VERSION"
    log_info ""

    _PREFLIGHT_PASS=0
    _PREFLIGHT_FAIL=0
    _PREFLIGHT_WARN=0

    _preflight_check_cpu
    _preflight_check_memory
    _preflight_check_disk
    _preflight_check_ports
    _preflight_check_kernel_modules
    _preflight_check_ip_forward
    _preflight_check_cri
    _preflight_check_swap
    _preflight_check_cgroups
    _preflight_check_selinux
    _preflight_check_apparmor
    _preflight_check_unattended_upgrades
    _preflight_check_existing_cluster
    _preflight_check_connectivity

    log_info ""
    log_info "=== Preflight Summary ==="
    log_info "  Passed: $_PREFLIGHT_PASS"
    log_info "  Failed: $_PREFLIGHT_FAIL"
    if [ "$_PREFLIGHT_WARN" -gt 0 ]; then
        log_warn "  Warnings: $_PREFLIGHT_WARN"
    else
        log_info "  Warnings: 0"
    fi

    if [ "$_PREFLIGHT_FAIL" -gt 0 ]; then
        log_error "Preflight checks failed. Please fix the issues above before proceeding."
        return 1
    fi

    # In strict mode, treat warnings as failures
    if [ "${PREFLIGHT_STRICT:-false}" = true ] && [ "$_PREFLIGHT_WARN" -gt 0 ]; then
        log_error "Preflight checks failed in strict mode ($_PREFLIGHT_WARN warnings treated as failures)."
        return 1
    fi

    log_info "All preflight checks passed."
    return 0
}

preflight_dry_run() {
    log_info "=== Dry-run: Preflight Checks ==="
    log_info "Mode: $PREFLIGHT_MODE | CRI: $PREFLIGHT_CRI | Proxy mode: $PREFLIGHT_PROXY_MODE"
    [ -n "$PREFLIGHT_K8S_VERSION" ] && log_info "Target Kubernetes version: $PREFLIGHT_K8S_VERSION"
    log_info "Checks to perform:"
    log_info "  1. CPU count (>= 2 cores)"
    log_info "  2. Memory (>= 1700 MB)"
    log_info "  3. Disk space"
    log_info "  4. Required ports availability"
    if [ "$PREFLIGHT_MODE" = "init" ]; then
        log_info "     Ports: 6443, 2379, 2380, 10250, 10259, 10257"
    else
        log_info "     Ports: 10250"
    fi
    log_info "  5. Kernel modules (overlay, br_netfilter + proxy-mode specific)"
    log_info "  6. IPv4 forwarding"
    log_info "  7. Container runtime ($PREFLIGHT_CRI) installation status"
    if [ "$PREFLIGHT_CRI" = "containerd" ]; then
        log_info "     containerd v2 readiness for Kubernetes 1.36+"
    fi
    log_info "  8. Swap state"
    log_info "  9. cgroups v2"
    log_info "  10. SELinux state"
    log_info "  11. AppArmor state"
    log_info "  12. Unattended upgrades detection"
    if [ "$PREFLIGHT_MODE" = "init" ]; then
        log_info "  13. Existing cluster detection"
    fi
    log_info "  14. Network connectivity (dl.k8s.io)"
    if [ "${PREFLIGHT_STRICT:-false}" = true ]; then
        log_info "  Strict mode: warnings will be treated as failures"
    fi
    log_info "=== End of dry-run (no changes made) ==="
}
