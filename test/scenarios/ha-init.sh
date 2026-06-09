#!/bin/bash
#
# HA (kube-vip) Integration Test — Init mode (single VM)
# Usage: ./test/scenarios/ha-init.sh [--distro <name>] [--k8s-version <ver>]
#
# Verifications:
#   1. setup-k8s.sh init --ha --ha-vip <VIP> completes successfully
#   2. kube-vip manifest deployed to /etc/kubernetes/manifests/
#   3. kubeadm init succeeded with --control-plane-endpoint
#   4. kubelet is active, API server is responsive
#   5. Certificate key and control-plane join info is displayed
#   6. setup-k8s.sh cleanup --force succeeds
#

set -euo pipefail

SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(cd "$SCENARIO_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
SCRIPT_DIR="$TEST_DIR"
# shellcheck source=test/lib/runner.sh
source "$TEST_DIR/lib/runner.sh"
cd "$TEST_DIR"

SETUP_K8S_SCRIPT="$PROJECT_ROOT/setup-k8s.sh"
DOCKER_VM_RUNNER_IMAGE="${DOCKER_VM_RUNNER_IMAGE:-ghcr.io/munenick/docker-vm-runner:latest}"
VM_DATA_DIR="${VM_DATA_DIR:-$SCRIPT_DIR/data}"

# Defaults
DISTRO="${DISTRO:-ubuntu-24.04-cloud-amd64}"
K8S_VERSION=""
VM_MEMORY="${VM_MEMORY:-8192}"
VM_CPUS="${VM_CPUS:-4}"
VM_DISK_SIZE="${VM_DISK_SIZE:-40G}"
HA_VIP="10.0.2.100"

TIMEOUT_TOTAL=1200
SSH_READY_TIMEOUT=300

# SSH settings
SSH_KEY_DIR=""
SSH_PORT=""
SSH_BASE_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
# shellcheck disable=SC2034 # SSH_OPTS is used by sourced vm_harness.sh
SSH_OPTS=("${SSH_BASE_OPTS[@]}")

# Cleanup state
_VM_CONTAINER_NAME=""
_WATCHDOG_PID=""
LOGIN_USER="user"

show_help() {
    cat <<EOF
HA (kube-vip) Integration Test — Init mode

Usage: $0 [OPTIONS]

Options:
  --distro <name>         Distribution to test (default: ubuntu-24.04-cloud-amd64)
  --k8s-version <ver>     Kubernetes version (e.g., 1.32)
  --ha-vip <addr>         VIP address (default: $HA_VIP)
  --memory <MB>           VM memory (default: $VM_MEMORY)
  --cpus <count>          VM CPUs (default: $VM_CPUS)
  --disk-size <size>      VM disk size (default: $VM_DISK_SIZE)
  --help, -h              Show this help message
EOF
}

_ha_cleanup_vm_container() {
    _cleanup_vm_container "$_WATCHDOG_PID" "$_VM_CONTAINER_NAME"
    _WATCHDOG_PID=""
    _VM_CONTAINER_NAME=""
}

run_ha_test() {
    local container_name
    container_name="k8s-ha-test-${DISTRO}-$(date +%s)"
    local log_file
    log_file="results/logs/ha-${DISTRO}-$(date +%Y%m%d-%H%M%S).log"

    log_info "=== HA (kube-vip) Integration Test ==="
    log_info "Distribution: $DISTRO"
    log_info "VIP: $HA_VIP"
    log_info "VM resources: memory=${VM_MEMORY}MB cpus=${VM_CPUS} disk=${VM_DISK_SIZE}"
    mkdir -p results/logs "$VM_DATA_DIR"
    test_validate_runner_distro "$DISTRO" || return 1

    # Clean up stale containers
    _ha_cleanup_vm_container
    cleanup_orphaned_containers "k8s-ha-test"

    _VM_CONTAINER_NAME=""
    trap '_ha_cleanup_vm_container; cleanup_ssh_key' EXIT INT TERM HUP

    setup_ssh_key
    SSH_PORT=$(find_free_port)

    # --- Start VM ---
    log_info "Starting container: $container_name (SSH port: $SSH_PORT)"
    docker run -d --rm \
        --name "$container_name" \
        --label "managed-by=k8s-ha-test" \
        --device /dev/kvm:/dev/kvm \
        -v "$VM_DATA_DIR:/data" \
        -p "${SSH_PORT}:2222" \
        -e "DISTRO=$DISTRO" \
        -e "GUEST_NAME=$container_name" \
        -e "SSH_PUBKEY=$(cat "$SSH_KEY_DIR/id_test.pub")" \
        -e "NO_CONSOLE=1" \
        -e "MEMORY=$VM_MEMORY" \
        -e "CPUS=$VM_CPUS" \
        -e "DISK_SIZE=$VM_DISK_SIZE" \
        "$DOCKER_VM_RUNNER_IMAGE" >/dev/null
    _VM_CONTAINER_NAME="$container_name"
    _WATCHDOG_PID=$(_start_vm_container_watchdog "$$" "$container_name")
    log_success "Container started"

    # --- Wait for cloud-init and SSH ---
    wait_for_cloud_init "$container_name" "$SSH_READY_TIMEOUT" "HA" || return 1
    wait_for_ssh "$SSH_PORT" "$LOGIN_USER" "$SSH_READY_TIMEOUT" "HA" || return 1
    wait_for_guest_bootstrap "$SSH_PORT" "$LOGIN_USER" "$SSH_READY_TIMEOUT" "HA" || return 1

    # --- Discover VM network ---
    local vm_ip vm_iface
    vm_ip=$(vm_ssh "hostname -I | awk '{print \$1}'" 2>/dev/null | tr -d '[:space:]')
    vm_iface=$(vm_ssh "ip route get 1 | awk '{print \$5; exit}'" 2>/dev/null | tr -d '[:space:]')
    log_info "VM IP: $vm_ip, interface: $vm_iface"

    # --- Deploy bundled scripts ---
    local setup_bundle
    setup_bundle=$(mktemp /tmp/setup-k8s-ha-bundle.XXXXXX.sh)
    log_info "Generating bundled script..."
    local _saved_k8s_version="$K8S_VERSION"
    _generate_bundle "$SETUP_K8S_SCRIPT" "$setup_bundle" "all"
    K8S_VERSION="$_saved_k8s_version"

    log_info "Transferring script to VM..."
    vm_scp "$setup_bundle" "/tmp/setup-k8s.sh"
    vm_ssh "chmod +x /tmp/setup-k8s.sh" >/dev/null 2>&1
    rm -f "$setup_bundle"
    log_success "Script deployed"

    # --- Resolve K8s version if not specified ---
    local k8s_version_flag="" k8s_version_val=""
    if [ -n "$K8S_VERSION" ]; then
        k8s_version_flag="--kubernetes-version"
        k8s_version_val="$K8S_VERSION"
    fi

    # ===================================================================
    # Phase 1: HA Init
    # ===================================================================
    log_info "=== Phase 1: HA Init (--ha --ha-vip $HA_VIP) ==="
    local ha_args
    ha_args="--ha --ha-vip $(printf '%q' "$HA_VIP") --ha-interface $(printf '%q' "$vm_iface")"
    if [ -n "$k8s_version_flag" ]; then
        log_info "Running: setup-k8s.sh init $k8s_version_flag $k8s_version_val $ha_args"
    else
        log_info "Running: setup-k8s.sh init $ha_args"
    fi

    local ha_init_cmd="bash /tmp/setup-k8s.sh init"
    [ -n "$k8s_version_flag" ] && ha_init_cmd+=" $(printf '%q' "$k8s_version_flag") $(printf '%q' "$k8s_version_val")"
    ha_init_cmd+=" $ha_args > /tmp/setup-k8s.log 2>&1; echo \$? > /tmp/setup-exit-code"
    vm_ssh "nohup bash -c '${ha_init_cmd}' </dev/null >/dev/null 2>&1 &"

    if ! poll_vm_command vm_ssh "$container_name" /tmp/setup-exit-code /tmp/setup-k8s.log "$TIMEOUT_TOTAL"; then
        vm_ssh "cat /tmp/setup-k8s.log" > "$log_file" 2>/dev/null || true
        return 1
    fi
    local setup_exit_code="$POLL_EXIT_CODE"
    log_info "Setup exit code: $setup_exit_code"

    # Save logs
    vm_ssh "cat /tmp/setup-k8s.log" > "$log_file" 2>/dev/null || true

    if [ "$setup_exit_code" -ne 0 ]; then
        log_error "=== SETUP LOG (last 40 lines) ==="
        tail -40 "$log_file"
        log_error "=== END ==="
        log_info "=== DIAGNOSTICS ==="
        log_info "IP addresses:"
        vm_ssh "ip addr show" 2>/dev/null || true
        log_info "Routing table:"
        vm_ssh "ip route" 2>/dev/null || true
        log_info "Listening ports:"
        vm_ssh "ss -tlnp | grep 6443" 2>/dev/null || true
        log_info "VIP connectivity test:"
        vm_ssh "curl -sk --connect-timeout 3 https://${HA_VIP}:6443/livez 2>&1 || echo 'VIP unreachable'" 2>/dev/null || true
        vm_ssh "curl -sk --connect-timeout 3 https://${vm_ip}:6443/livez 2>&1 || echo 'NodeIP unreachable'" 2>/dev/null || true
        log_info "kube-vip manifest:"
        vm_ssh "cat /etc/kubernetes/manifests/kube-vip.yaml 2>/dev/null || echo 'not found'" 2>/dev/null || true
        log_info "kube-vip pod status (crictl):"
        vm_ssh "crictl ps -a 2>/dev/null | grep -i vip || echo 'no kube-vip container'" 2>/dev/null || true
        log_info "=== END DIAGNOSTICS ==="
        return 1
    fi
    log_success "HA init completed (exit 0)"

    # ===================================================================
    # Phase 2: Verify HA-specific artifacts
    # ===================================================================
    log_info "=== Phase 2: HA Verification ==="

    local all_pass=true

    # Check 1: kube-vip manifest exists
    if vm_ssh "test -f /etc/kubernetes/manifests/kube-vip.yaml" >/dev/null 2>&1; then
        log_success "CHECK: kube-vip.yaml manifest exists"
    else
        log_error "CHECK: kube-vip.yaml manifest NOT found"
        all_pass=false
    fi

    # Check 2: kube-vip manifest contains VIP
    if vm_ssh "grep -q -F $(printf '%q' "$HA_VIP") /etc/kubernetes/manifests/kube-vip.yaml" >/dev/null 2>&1; then
        log_success "CHECK: kube-vip manifest contains VIP ($HA_VIP)"
    else
        log_error "CHECK: kube-vip manifest does not contain VIP"
        all_pass=false
    fi

    # Check 3: kube-vip manifest contains interface
    if vm_ssh "grep -q -F $(printf '%q' "$vm_iface") /etc/kubernetes/manifests/kube-vip.yaml" >/dev/null 2>&1; then
        log_success "CHECK: kube-vip manifest contains interface ($vm_iface)"
    else
        log_error "CHECK: kube-vip manifest does not contain interface"
        all_pass=false
    fi

    # Check 4: kubelet is active
    local kubelet_status
    kubelet_status=$(vm_ssh "systemctl is-active kubelet" 2>/dev/null | tr -d '[:space:]') || kubelet_status="inactive"
    if [ "$kubelet_status" = "active" ]; then
        log_success "CHECK: kubelet is active"
    else
        log_error "CHECK: kubelet is $kubelet_status"
        all_pass=false
    fi

    # Check 5: kubeconfig exists
    if vm_ssh "test -f /etc/kubernetes/admin.conf" >/dev/null 2>&1; then
        log_success "CHECK: admin.conf exists"
    else
        log_error "CHECK: admin.conf NOT found"
        all_pass=false
    fi

    # Check 6: API server responsive
    # Try with VIP first, fall back to node IP
    local api_server_args=""
    if vm_ssh "timeout 30 kubectl get nodes --kubeconfig=/etc/kubernetes/admin.conf" >/dev/null 2>&1; then
        log_success "CHECK: API server responsive (via kubeconfig)"
    else
        # kubeconfig might point to VIP which may not be reachable in PASST mode
        # Try directly via node IP
        if vm_ssh "timeout 30 kubectl get nodes --kubeconfig=/etc/kubernetes/admin.conf --server=https://${vm_ip}:6443 --insecure-skip-tls-verify" >/dev/null 2>&1; then
            api_server_args="--server=https://${vm_ip}:6443 --insecure-skip-tls-verify"
            log_warn "CHECK: API server responsive (via node IP fallback, VIP may not work in PASST networking)"
        else
            log_error "CHECK: API server NOT responsive"
            all_pass=false
        fi
    fi

    # Check 7: control-plane-endpoint set correctly in kubeadm-config
    if vm_ssh "kubectl get configmap kubeadm-config -n kube-system -o yaml --kubeconfig=/etc/kubernetes/admin.conf ${api_server_args} 2>/dev/null | grep -q 'controlPlaneEndpoint'" >/dev/null 2>&1; then
        log_success "CHECK: controlPlaneEndpoint set in kubeadm-config"
    else
        log_warn "CHECK: Could not verify controlPlaneEndpoint in kubeadm-config (non-fatal)"
    fi

    # Check 8: setup log contains HA join info
    if grep -q "HA Cluster: Control-Plane Join Information" "$log_file" 2>/dev/null; then
        log_success "CHECK: HA join info displayed in output"
    else
        log_error "CHECK: HA join info NOT found in output"
        all_pass=false
    fi

    # Check 9: certificate key in output
    if grep -q "Certificate key:" "$log_file" 2>/dev/null; then
        log_success "CHECK: Certificate key displayed"
    else
        log_error "CHECK: Certificate key NOT found in output"
        all_pass=false
    fi

    # Show kube-vip pod status (use grep instead of field-selector which doesn't support wildcards)
    log_info "kube-vip pod status:"
    vm_ssh "kubectl get pods -n kube-system --kubeconfig=/etc/kubernetes/admin.conf ${api_server_args} 2>/dev/null | grep -E 'NAME|kube-vip' || echo '(could not query pods)'" 2>/dev/null || true

    # ===================================================================
    # Phase 3: Cleanup
    # ===================================================================
    log_info "=== Phase 3: Cleanup ==="
    vm_ssh "nohup bash -c 'bash /tmp/setup-k8s.sh cleanup --force > /tmp/cleanup-k8s.log 2>&1; echo \$? > /tmp/cleanup-exit-code' </dev/null >/dev/null 2>&1 &"

    local cleanup_exit_code
    if ! poll_vm_command vm_ssh "$container_name" /tmp/cleanup-exit-code /tmp/cleanup-k8s.log "$TIMEOUT_TOTAL"; then
        log_warn "Cleanup polling failed (timeout or container exit)"
        cleanup_exit_code=1
    else
        cleanup_exit_code="$POLL_EXIT_CODE"
    fi
    if [ "$cleanup_exit_code" -eq 0 ]; then
        log_success "Cleanup completed (exit 0)"
    else
        log_error "Cleanup failed (exit $cleanup_exit_code)"
        all_pass=false
    fi

    # Append cleanup logs
    vm_ssh "cat /tmp/cleanup-k8s.log" >> "$log_file" 2>/dev/null || true

    # ===================================================================
    # Result
    # ===================================================================
    echo ""
    log_info "Log file: $log_file"
    if [ "$all_pass" = true ]; then
        log_success "=== HA TEST PASSED ==="
        _ha_cleanup_vm_container
        cleanup_ssh_key
        trap - EXIT INT TERM HUP
        return 0
    else
        log_error "=== HA TEST FAILED ==="
        _ha_cleanup_vm_container
        cleanup_ssh_key
        trap - EXIT INT TERM HUP
        return 1
    fi
}

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h) show_help; exit 0 ;;
        --distro) _require_arg $# "$1"; DISTRO="$2"; shift 2 ;;
        --k8s-version) _require_arg $# "$1"; K8S_VERSION="$2"; shift 2 ;;
        --ha-vip) _require_arg $# "$1"; HA_VIP="$2"; shift 2 ;;
        --memory) _require_arg $# "$1"; VM_MEMORY="$2"; shift 2 ;;
        --cpus) _require_arg $# "$1"; VM_CPUS="$2"; shift 2 ;;
        --disk-size) _require_arg $# "$1"; VM_DISK_SIZE="$2"; shift 2 ;;
        --failover) shift ;;  # ignore, handled by dispatcher
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

if run_ha_test; then exit 0; else exit 1; fi
