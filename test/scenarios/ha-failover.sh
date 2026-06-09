#!/bin/bash
#
# HA Failover Integration Test — 3-CP deploy mode
# Usage: ./test/scenarios/ha-failover.sh [--distro <name>] [--k8s-version <ver>]
#
# Verifications:
#   1. Deploy 3 CP HA cluster via setup-k8s.sh deploy
#   2. Verify all 3 nodes Ready + cluster healthy
#   3. Stop 1 CP node (simulate failure)
#   4. Verify cluster continues operating (API server responds, kubectl works)
#   5. Verify kube-vip manifests on surviving nodes
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

TIMEOUT_TOTAL=1200
SSH_READY_TIMEOUT=300

# SSH settings
SSH_KEY_DIR=""
SSH_BASE_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
# shellcheck disable=SC2034 # SSH_OPTS is used by sourced vm_harness.sh
SSH_OPTS=("${SSH_BASE_OPTS[@]}")
LOGIN_USER="user"

# Failover mode state (3 CP VMs)
DOCKER_NETWORK="${DOCKER_NETWORK:-k8s-ha-net-$$}"
DOCKER_SUBNET="${DOCKER_SUBNET:-172.31.0.0/24}"
_FO_CONTAINER_NAMES=()
_FO_WATCHDOG_PIDS=()
_FO_SSH_PORTS=()
_FO_DOCKER_IPS=("172.31.0.10" "172.31.0.11" "172.31.0.12")
_FO_HA_VIP="172.31.0.100"
NUM_CP_NODES=3

show_help() {
    cat <<EOF
HA Failover Integration Test — 3-CP deploy mode

Usage: $0 [OPTIONS]

Options:
  --distro <name>         Distribution to test (default: ubuntu-24.04-cloud-amd64)
  --k8s-version <ver>     Kubernetes version (e.g., 1.32)
  --memory <MB>           VM memory (default: $VM_MEMORY)
  --cpus <count>          VM CPUs (default: $VM_CPUS)
  --disk-size <size>      VM disk size (default: $VM_DISK_SIZE)
  --help, -h              Show this help message
EOF
}

_fo_cleanup_all() {
    for i in "${!_FO_CONTAINER_NAMES[@]}"; do
        _cleanup_vm_container "${_FO_WATCHDOG_PIDS[$i]:-}" "${_FO_CONTAINER_NAMES[$i]:-}"
    done
    _FO_CONTAINER_NAMES=()
    _FO_WATCHDOG_PIDS=()
    cleanup_docker_network
    cleanup_ssh_key
}

# Start a VM with static IP on Docker network (HA-specific: includes etcd ports)
_fo_start_vm() {
    local idx=$1 static_ip=$2 host_ssh_port=$3
    local container_name
    container_name="k8s-ha-fo-cp$((idx+1))-${DISTRO}-$(date +%s)"
    local vm_data_dir="$VM_DATA_DIR/ha-cp$((idx+1))"
    mkdir -p "$vm_data_dir"

    log_info "Starting CP $((idx+1))/$NUM_CP_NODES: $container_name (IP: $static_ip, SSH: $host_ssh_port)"
    # NETWORK_GUEST_IP sets the VM's internal IP to the Docker network IP.
    # This is required for HA: kubeadm uses this IP for etcd peer URLs and
    # apiserver advertise address, enabling inter-node communication via
    # passt port forwarding through Docker network IPs.
    docker run -d --rm \
        --name "$container_name" \
        --label "managed-by=k8s-ha-failover-test" \
        --network "$DOCKER_NETWORK" --ip "$static_ip" \
        --device /dev/kvm:/dev/kvm \
        -v "$vm_data_dir:/data" \
        -p "${host_ssh_port}:2222" \
        -e "DISTRO=$DISTRO" \
        -e "GUEST_NAME=$container_name" \
        -e "SSH_PUBKEY=$(cat "$SSH_KEY_DIR/id_test.pub")" \
        -e "PORT_FWD=6443:6443,10250:10250,2379:2379,2380:2380" \
        -e "NETWORK_GUEST_IP=$static_ip" \
        -e "NO_CONSOLE=1" \
        -e "MEMORY=$VM_MEMORY" \
        -e "CPUS=$VM_CPUS" \
        -e "DISK_SIZE=$VM_DISK_SIZE" \
        "$DOCKER_VM_RUNNER_IMAGE" >/dev/null

    _FO_CONTAINER_NAMES[$idx]="$container_name"
    _FO_WATCHDOG_PIDS[$idx]=$(_start_vm_container_watchdog "$$" "$container_name")
    _FO_SSH_PORTS[$idx]="$host_ssh_port"
    log_success "Container $container_name started"
}

run_failover_test() {
    log_info "=== HA Failover Test (3 CP, deploy mode) ==="
    log_info "Distribution: $DISTRO"
    log_info "VIP: $_FO_HA_VIP"
    log_info "VM resources: memory=${VM_MEMORY}MB cpus=${VM_CPUS} disk=${VM_DISK_SIZE}"
    log_info "Docker network: $DOCKER_NETWORK ($DOCKER_SUBNET)"
    mkdir -p results/logs "$VM_DATA_DIR"
    test_validate_runner_distro "$DISTRO" || return 1

    cleanup_orphaned_containers "k8s-ha-failover-test"
    trap '_fo_cleanup_all' EXIT INT TERM HUP

    # --- Step 1: Infrastructure ---
    setup_docker_network
    setup_ssh_key

    # --- Step 2: Start 3 VMs ---
    log_info "=== Step 1: Starting $NUM_CP_NODES VMs ==="
    for i in $(seq 0 $((NUM_CP_NODES - 1))); do
        local ssh_port
        ssh_port=$(find_free_port)
        _fo_start_vm "$i" "${_FO_DOCKER_IPS[$i]}" "$ssh_port"
    done

    # Wait for VMs
    for i in $(seq 0 $((NUM_CP_NODES - 1))); do
        wait_for_cloud_init "${_FO_CONTAINER_NAMES[$i]}" "$SSH_READY_TIMEOUT" "CP$((i+1))" || return 1
        wait_for_ssh "${_FO_SSH_PORTS[$i]}" "$LOGIN_USER" "$SSH_READY_TIMEOUT" "CP$((i+1))" || return 1
        wait_for_guest_bootstrap "${_FO_SSH_PORTS[$i]}" "$LOGIN_USER" "$SSH_READY_TIMEOUT" "CP$((i+1))" || return 1
        setup_root_ssh "${_FO_SSH_PORTS[$i]}" "CP$((i+1))"
    done
    log_success "All $NUM_CP_NODES VMs ready"

    # --- Step 3: Resolve K8s version ---
    resolve_k8s_version || return 1

    # --- Step 4: Deploy 3 CP HA cluster ---
    log_info "=== Step 2: Deploying HA cluster ==="
    local cp_list="${_FO_DOCKER_IPS[0]}"
    for i in $(seq 1 $((NUM_CP_NODES - 1))); do
        cp_list="${cp_list},${_FO_DOCKER_IPS[$i]}"
    done

    # Discover interface inside first VM
    local vm_iface
    vm_iface=$(vm_ssh_root "${_FO_SSH_PORTS[0]}" "ip route get 1 | awk '{print \$5; exit}'" 2>/dev/null | tr -d '[:space:]')
    log_info "VM network interface: $vm_iface"

    # NAT (passt) mode: VIP is not reachable between VMs because passt
    # does not expose IPs added inside the VM to the Docker network.
    # Use CP1's Docker IP as control-plane-endpoint.
    # kube-vip manifest is still deployed via --ha-vip/--ha-interface.
    local deploy_cmd=(
        bash "$SETUP_K8S_SCRIPT" deploy
        --control-planes "$cp_list"
        --ha-vip "$_FO_HA_VIP"
        --ha-interface "$vm_iface"
        --control-plane-endpoint "${_FO_DOCKER_IPS[0]}:6443"
        --ssh-user root
        --ssh-port 2222
        --ssh-key "$SSH_KEY_DIR/id_test"
        --ssh-host-key-check accept-new
        --kubernetes-version "$K8S_VERSION"
    )
    log_info "Command: ${deploy_cmd[*]}"

    local log_file
    log_file="results/logs/ha-failover-${DISTRO}-$(date +%Y%m%d-%H%M%S).log"

    local deploy_exit_code=0
    if timeout "$TIMEOUT_TOTAL" "${deploy_cmd[@]}" 2>&1 | tee "$log_file"; then
        deploy_exit_code=0
    else
        deploy_exit_code=$?
    fi

    if [ "$deploy_exit_code" -ne 0 ]; then
        log_error "HA cluster deployment failed (exit $deploy_exit_code)"
        return 1
    fi
    log_success "HA cluster deployed"

    # --- Step 5: Verify cluster health (no CNI required) ---
    log_info "=== Step 3: Verifying cluster health ==="
    local all_pass=true

    # Check node count (nodes may be NotReady without CNI, that's OK)
    local elapsed=0 timeout=120
    while [ "$elapsed" -lt "$timeout" ]; do
        local node_count
        node_count=$(vm_ssh_root "${_FO_SSH_PORTS[0]}" \
            "kubectl get nodes --no-headers --kubeconfig=/etc/kubernetes/admin.conf 2>/dev/null | wc -l" \
            2>/dev/null | tr -d '[:space:]')
        if [ "${node_count:-0}" -eq "$NUM_CP_NODES" ] 2>/dev/null; then
            log_success "CHECK: Node count = $node_count (expected $NUM_CP_NODES)"
            break
        fi
        log_info "  Waiting for nodes: ${node_count:-0}/$NUM_CP_NODES registered"
        sleep 10
        elapsed=$((elapsed + 10))
    done
    if [ "$elapsed" -ge "$timeout" ]; then
        log_error "Not all nodes registered within ${timeout}s"
        vm_ssh_root "${_FO_SSH_PORTS[0]}" "kubectl get nodes --kubeconfig=/etc/kubernetes/admin.conf" 2>/dev/null || true
        all_pass=false
    fi

    # API server health
    if vm_ssh_root "${_FO_SSH_PORTS[0]}" "kubectl get --raw /readyz --kubeconfig=/etc/kubernetes/admin.conf" >/dev/null 2>&1; then
        log_success "CHECK: API server is ready"
    else
        log_error "CHECK: API server not ready"
        all_pass=false
    fi

    # kubelet active on all nodes
    for i in $(seq 0 $((NUM_CP_NODES - 1))); do
        local kubelet_status
        kubelet_status=$(vm_ssh_root "${_FO_SSH_PORTS[$i]}" \
            "systemctl is-active kubelet" 2>/dev/null | tr -d '[:space:]') || kubelet_status="unknown"
        if [ "$kubelet_status" = "active" ]; then
            log_success "CHECK: CP $((i+1)) kubelet is active"
        else
            log_error "CHECK: CP $((i+1)) kubelet is $kubelet_status"
            all_pass=false
        fi
    done

    # etcd member count
    local etcd_pods
    etcd_pods=$(vm_ssh_root "${_FO_SSH_PORTS[0]}" \
        "kubectl get pods -n kube-system -l component=etcd --no-headers --kubeconfig=/etc/kubernetes/admin.conf 2>/dev/null | wc -l" \
        2>/dev/null | tr -d '[:space:]')
    if [ "$etcd_pods" = "$NUM_CP_NODES" ]; then
        log_success "CHECK: etcd has $etcd_pods members"
    else
        log_warn "CHECK: etcd members: ${etcd_pods:-0} (expected $NUM_CP_NODES)"
    fi

    # Show node status for debugging
    vm_ssh_root "${_FO_SSH_PORTS[0]}" \
        "kubectl get nodes -o wide --kubeconfig=/etc/kubernetes/admin.conf" 2>/dev/null || true

    [ "$all_pass" != true ] && return 1

    # --- Step 6: Simulate CP failure ---
    log_info "=== Step 4: Simulating CP node failure ==="
    local failed_idx=$((NUM_CP_NODES - 1))
    local failed_container="${_FO_CONTAINER_NAMES[$failed_idx]}"
    local failed_ip="${_FO_DOCKER_IPS[$failed_idx]}"
    log_info "Stopping CP $((failed_idx + 1)) ($failed_ip, $failed_container)..."
    docker stop "$failed_container" >/dev/null 2>&1 || true
    log_info "Waiting 20s for cluster to detect node loss..."
    sleep 20
    log_success "CP $((failed_idx + 1)) stopped"

    # --- Step 7: Verify cluster survives ---
    log_info "=== Step 5: Verifying cluster survives failure ==="
    local fo_elapsed=0 fo_timeout=120
    while [ "$fo_elapsed" -lt "$fo_timeout" ]; do
        if vm_ssh_root "${_FO_SSH_PORTS[0]}" \
            "kubectl get --raw /readyz --kubeconfig=/etc/kubernetes/admin.conf" >/dev/null 2>&1; then
            log_success "CHECK: API server still responds after CP failure"
            break
        fi
        sleep 5
        fo_elapsed=$((fo_elapsed + 5))
    done
    if [ "$fo_elapsed" -ge "$fo_timeout" ]; then
        log_error "CHECK: API server not responding after failover timeout"
        all_pass=false
    fi

    # kubectl operations
    if vm_ssh_root "${_FO_SSH_PORTS[0]}" \
        "kubectl get nodes --kubeconfig=/etc/kubernetes/admin.conf" >/dev/null 2>&1; then
        log_success "CHECK: kubectl get nodes succeeds"
    else
        log_error "CHECK: kubectl get nodes failed"
        all_pass=false
    fi

    # Create a test pod
    vm_ssh_root "${_FO_SSH_PORTS[0]}" \
        "kubectl run ha-test-pod --image=busybox --restart=Never --kubeconfig=/etc/kubernetes/admin.conf -- sleep 30" >/dev/null 2>&1 || true
    sleep 5
    vm_ssh_root "${_FO_SSH_PORTS[0]}" \
        "kubectl delete pod ha-test-pod --ignore-not-found --kubeconfig=/etc/kubernetes/admin.conf" >/dev/null 2>&1 || true

    # --- Step 8: Verify kube-vip manifests ---
    # VIP failover cannot be tested in NAT (passt) mode because VIPs added
    # inside the VM are not visible on the Docker network. Verify that
    # kube-vip manifests were deployed on surviving nodes instead.
    log_info "=== Step 6: Verifying kube-vip manifests ==="
    local kubevip_ok=true
    for i in $(seq 0 $((NUM_CP_NODES - 2))); do
        local has_manifest
        has_manifest=$(vm_ssh_root "${_FO_SSH_PORTS[$i]}" \
            "test -f /etc/kubernetes/manifests/kube-vip.yaml && echo yes || echo no" 2>/dev/null | tr -d '[:space:]')
        if [ "$has_manifest" = "yes" ]; then
            log_success "CHECK: kube-vip manifest present on CP $((i+1))"
        else
            log_error "CHECK: kube-vip manifest missing on CP $((i+1))"
            kubevip_ok=false
        fi
    done
    if [ "$kubevip_ok" = true ]; then
        log_success "kube-vip manifests verified on all surviving nodes"
    else
        log_warn "Some kube-vip manifests missing"
    fi

    # Show final node status
    log_info "Final node status:"
    vm_ssh_root "${_FO_SSH_PORTS[0]}" \
        "kubectl get nodes -o wide --kubeconfig=/etc/kubernetes/admin.conf" 2>/dev/null || true

    # --- Result ---
    echo ""
    log_info "Log file: $log_file"
    if [ "$all_pass" = true ]; then
        log_success "=== HA FAILOVER TEST PASSED ==="
        _fo_cleanup_all
        trap - EXIT INT TERM HUP
        return 0
    else
        log_error "=== HA FAILOVER TEST FAILED ==="
        _fo_cleanup_all
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
        --memory) _require_arg $# "$1"; VM_MEMORY="$2"; shift 2 ;;
        --cpus) _require_arg $# "$1"; VM_CPUS="$2"; shift 2 ;;
        --disk-size) _require_arg $# "$1"; VM_DISK_SIZE="$2"; shift 2 ;;
        --failover) shift ;;  # ignore, handled by dispatcher
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

if run_failover_test; then exit 0; else exit 1; fi
