#!/bin/bash
#
# Deploy Subcommand E2E Test via docker-vm-runner
# Usage: ./test/scenarios/deploy-remove.sh [--distro <name>] [--k8s-version <ver>]
#
# Scenario: Single CP + Single Worker (key-based SSH)
#
# Tests (Phase 1: Deploy Verification):
#   1. setup-k8s.sh deploy completes successfully (exit 0)
#   2. CP: kubelet is active
#   3. CP: /etc/kubernetes/admin.conf exists
#   4. CP: kubectl get nodes responds
#   5. Total node count = 2 (1 CP + 1 Worker)
#   6. Worker: kubelet is active
#
# Tests (Phase 2: Remove Verification):
#   7. setup-k8s.sh remove completes successfully (exit 0)
#   8. Total node count = 1 (Worker removed)
#   9. Worker: kubelet is inactive (kubeadm reset)
#  10. CP: kubelet is still active
#
# Test matrix (combine with --cri / --proxy-mode flags):
#   ./scenarios/deploy-remove.sh --cri crio
#   ./scenarios/deploy-remove.sh --proxy-mode ipvs
#   ./scenarios/deploy-remove.sh --proxy-mode nftables
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
VM_DATA_DIR="${VM_DATA_DIR:-$SCRIPT_DIR/data}"

# Defaults (common defaults from vm_harness.sh: VM_MEMORY, VM_CPUS, VM_DISK_SIZE, TIMEOUT_TOTAL, SSH_READY_TIMEOUT)
DISTRO="${DISTRO:-ubuntu-24.04-cloud-amd64}"
K8S_VERSION=""
DEPLOY_CRI=""
DEPLOY_PROXY_MODE=""

# Docker network for VM-to-VM communication (overridable via environment)
DOCKER_NETWORK="${DOCKER_NETWORK:-k8s-deploy-net-$$}"
DOCKER_SUBNET="${DOCKER_SUBNET:-10.202.0.0/24}"
CP_DOCKER_IP="${CP_DOCKER_IP:-10.202.0.10}"
WORKER_DOCKER_IP="${WORKER_DOCKER_IP:-10.202.0.20}"

# SSH settings & cleanup state
SSH_KEY_DIR=""
_init_test_defaults
_WORKER_CONTAINER_NAME=""
_WORKER_WATCHDOG_PID=""
_WORKER_SSH_PORT=""

show_help() {
    cat <<EOF
Deploy Subcommand E2E Test

Usage: $0 [OPTIONS]

Options:
  --distro <name>         Distribution to test (default: $DISTRO)
  --k8s-version <ver>     Kubernetes version (e.g., 1.32)
  --cri <runtime>         Container runtime: containerd or crio
  --proxy-mode <mode>     Proxy mode: iptables, ipvs, or nftables
  --memory <MB>           VM memory (default: $VM_MEMORY)
  --cpus <count>          VM CPUs (default: $VM_CPUS)
  --disk-size <size>      VM disk size (default: $VM_DISK_SIZE)
  --help, -h              Show this help message
EOF
}

# --- Main test logic ---

run_deploy_test() {
    _test_preamble "deploy" "$DISTRO"
    local cp_container="k8s-deploy-cp-${DISTRO}-${_TEST_TS}"
    local worker_container="k8s-deploy-w-${DISTRO}-${_TEST_TS}"
    local log_file="$_TEST_LOG_FILE"

    log_info "VM resources: memory=${VM_MEMORY}MB cpus=${VM_CPUS} disk=${VM_DISK_SIZE}"
    log_info "Docker network: $DOCKER_NETWORK ($DOCKER_SUBNET)"
    log_info "CP: $CP_DOCKER_IP, Worker: $WORKER_DOCKER_IP"

    trap '_cleanup_cp_worker' EXIT INT TERM HUP

    # --- Setup VM environment ---
    create_cp_worker_env "$cp_container" "$worker_container" "cp" "worker" "k8s-deploy-test" "k8s-deploy-test"

    # --- Resolve K8s version ---
    resolve_k8s_version || return 1

    # --- Step 6: Run deploy ---
    log_info "=== Running deploy ==="
    local deploy_cmd=(
        bash "$SETUP_K8S_SCRIPT" deploy
        --control-planes "$CP_DOCKER_IP"
        --workers "$WORKER_DOCKER_IP"
        --ssh-user root
        --ssh-port 2222
        --ssh-key "$SSH_KEY_DIR/id_test"
        --ssh-host-key-check accept-new
        --kubernetes-version "$K8S_VERSION"
        --control-plane-endpoint "${CP_DOCKER_IP}:6443"
    )
    [ -n "$DEPLOY_CRI" ] && deploy_cmd+=(--cri "$DEPLOY_CRI")
    [ -n "$DEPLOY_PROXY_MODE" ] && deploy_cmd+=(--proxy-mode "$DEPLOY_PROXY_MODE")
    log_info "Command: ${deploy_cmd[*]}"

    local deploy_exit_code=0
    run_with_timeout deploy_exit_code "$log_file" "${deploy_cmd[@]}"
    if [ "$deploy_exit_code" -eq 124 ]; then
        log_info "=== TIMEOUT DIAGNOSTICS ==="
        log_info "CP container status:"
        docker inspect --format='{{.State.Status}}' "$cp_container" 2>/dev/null || true
        log_info "Worker container status:"
        docker inspect --format='{{.State.Status}}' "$worker_container" 2>/dev/null || true
        log_info "=== END TIMEOUT DIAGNOSTICS ==="
    fi

    # ===================================================================
    # Phase 1: Deploy Verification
    # ===================================================================
    log_info "=== Phase 1: Deploy Verification ==="

    local all_pass=true

    # Check 1: deploy exit code = 0
    if [ "$deploy_exit_code" -eq 0 ]; then
        log_success "CHECK 1: deploy exit code = 0"
    else
        log_error "CHECK 1: deploy exit code = $deploy_exit_code"
        all_pass=false
    fi

    # Check 2: CP kubelet active
    local kubelet_status
    kubelet_status=$(vm_ssh_root "$_CP_SSH_PORT" "systemctl is-active kubelet" 2>/dev/null | tr -d '[:space:]') || kubelet_status="inactive"
    if [ "$kubelet_status" = "active" ]; then
        log_success "CHECK 2: CP kubelet is active"
    else
        log_error "CHECK 2: CP kubelet is $kubelet_status"
        all_pass=false
    fi

    # Check 3: CP admin.conf exists
    if vm_ssh_root "$_CP_SSH_PORT" "test -f /etc/kubernetes/admin.conf" >/dev/null 2>&1; then
        log_success "CHECK 3: CP admin.conf exists"
    else
        log_error "CHECK 3: CP admin.conf NOT found"
        all_pass=false
    fi

    # Check 4: CP API server responsive
    if vm_ssh_root "$_CP_SSH_PORT" "timeout 30 kubectl get nodes --kubeconfig=/etc/kubernetes/admin.conf" >/dev/null 2>&1; then
        log_success "CHECK 4: CP API server responsive"
    else
        log_error "CHECK 4: CP API server NOT responsive"
        all_pass=false
    fi

    # Check 5: Node count = 2
    local node_count
    node_count=$(vm_ssh_root "$_CP_SSH_PORT" "kubectl get nodes --no-headers --kubeconfig=/etc/kubernetes/admin.conf 2>/dev/null | wc -l" 2>/dev/null | tr -d '[:space:]') || node_count="0"
    if [ "$node_count" -eq 2 ]; then
        log_success "CHECK 5: Node count = $node_count (expected 2)"
    else
        log_error "CHECK 5: Node count = $node_count (expected 2)"
        all_pass=false
    fi

    # Check 6: Worker kubelet active
    local worker_kubelet
    worker_kubelet=$(vm_ssh_root "$_WORKER_SSH_PORT" "systemctl is-active kubelet" 2>/dev/null | tr -d '[:space:]') || worker_kubelet="inactive"
    if [ "$worker_kubelet" = "active" ]; then
        log_success "CHECK 6: Worker kubelet is active"
    else
        log_error "CHECK 6: Worker kubelet is $worker_kubelet"
        all_pass=false
    fi

    # Show node list for debugging
    log_info "Node status:"
    vm_ssh_root "$_CP_SSH_PORT" "kubectl get nodes -o wide --kubeconfig=/etc/kubernetes/admin.conf" 2>/dev/null || true

    # If deploy verification failed, skip Phase 2
    if [ "$all_pass" != true ]; then
        echo ""
        log_error "=== DEPLOY VERIFICATION FAILED — skipping Phase 2 ==="
        log_info "Log file: $log_file"
        collect_vm_diagnostics "$cp_container" "$_CP_SSH_PORT"
        collect_vm_diagnostics "$worker_container" "$_WORKER_SSH_PORT"
        _cleanup_cp_worker
        trap - EXIT INT TERM HUP
        return 1
    fi

    # ===================================================================
    # Phase 2: Remove
    # ===================================================================
    log_info "=== Phase 2: Remove ==="

    local remove_log_file
    remove_log_file="results/logs/remove-${DISTRO}-$(date +%Y%m%d-%H%M%S).log"

    local remove_cmd=(
        bash "$SETUP_K8S_SCRIPT" remove
        --control-planes "root@${CP_DOCKER_IP}"
        --workers "root@${WORKER_DOCKER_IP}"
        --force
        --ssh-port 2222
        --ssh-key "$SSH_KEY_DIR/id_test"
        --ssh-host-key-check accept-new
    )
    log_info "Command: ${remove_cmd[*]}"

    local remove_exit_code=0
    run_with_timeout remove_exit_code "$remove_log_file" "${remove_cmd[@]}"

    # ===================================================================
    # Phase 2: Remove Verification
    # ===================================================================
    log_info "=== Phase 2: Remove Verification ==="

    # Check 7: remove exit code = 0
    if [ "$remove_exit_code" -eq 0 ]; then
        log_success "CHECK 7: remove exit code = 0"
    else
        log_error "CHECK 7: remove exit code = $remove_exit_code"
        all_pass=false
    fi

    # Check 8: Node count = 1 (Worker removed)
    local post_remove_node_count
    post_remove_node_count=$(vm_ssh_root "$_CP_SSH_PORT" "kubectl get nodes --no-headers --kubeconfig=/etc/kubernetes/admin.conf 2>/dev/null | wc -l" 2>/dev/null | tr -d '[:space:]') || post_remove_node_count="unknown"
    if [ "$post_remove_node_count" -eq 1 ] 2>/dev/null; then
        log_success "CHECK 8: Node count = $post_remove_node_count (expected 1)"
    else
        log_error "CHECK 8: Node count = $post_remove_node_count (expected 1)"
        all_pass=false
    fi

    # Check 9: Worker kubelet is inactive (kubeadm reset)
    local worker_kubelet_post
    worker_kubelet_post=$(vm_ssh_root "$_WORKER_SSH_PORT" "systemctl is-active kubelet" 2>/dev/null | tr -d '[:space:]') || worker_kubelet_post="inactive"
    if [ "$worker_kubelet_post" = "inactive" ]; then
        log_success "CHECK 9: Worker kubelet is inactive (reset confirmed)"
    else
        log_error "CHECK 9: Worker kubelet is $worker_kubelet_post (expected inactive)"
        all_pass=false
    fi

    # Check 10: CP kubelet is still active
    local cp_kubelet_post
    cp_kubelet_post=$(vm_ssh_root "$_CP_SSH_PORT" "systemctl is-active kubelet" 2>/dev/null | tr -d '[:space:]') || cp_kubelet_post="inactive"
    if [ "$cp_kubelet_post" = "active" ]; then
        log_success "CHECK 10: CP kubelet is still active"
    else
        log_error "CHECK 10: CP kubelet is $cp_kubelet_post (expected active)"
        all_pass=false
    fi

    # Show node list for debugging
    log_info "Node status after remove:"
    vm_ssh_root "$_CP_SSH_PORT" "kubectl get nodes -o wide --kubeconfig=/etc/kubernetes/admin.conf" 2>/dev/null || true

    # ===================================================================
    # Result
    # ===================================================================
    echo ""
    log_info "Deploy log: $log_file"
    log_info "Remove log: $remove_log_file"
    _test_result "DEPLOY + REMOVE" "$all_pass" _cleanup_cp_worker "$cp_container" "$_CP_SSH_PORT"
}

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    if _parse_common_test_args "$@"; then shift "$SHIFT_COUNT"; continue; fi
    case $1 in
        --help|-h) show_help; exit 0 ;;
        --cri) _require_arg $# "$1"; DEPLOY_CRI="$2"; shift 2 ;;
        --proxy-mode) _require_arg $# "$1"; DEPLOY_PROXY_MODE="$2"; shift 2 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

if run_deploy_test; then
    exit 0
else
    exit 1
fi
