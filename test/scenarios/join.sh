#!/bin/bash
#
# Join Subcommand E2E Test via docker-vm-runner
# Usage: ./test/scenarios/join.sh [--distro <name>] [--k8s-version <ver>]
#
# Scenario: init one control-plane, then join one worker with setup-k8s.sh join.
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

DISTRO="${DISTRO:-ubuntu-24.04-cloud-amd64}"
K8S_VERSION=""

DOCKER_NETWORK="${DOCKER_NETWORK:-k8s-join-net-$$}"
DOCKER_SUBNET="${DOCKER_SUBNET:-10.207.0.0/24}"
CP_DOCKER_IP="${CP_DOCKER_IP:-10.207.0.10}"
WORKER_DOCKER_IP="${WORKER_DOCKER_IP:-10.207.0.20}"

SSH_KEY_DIR=""
_init_test_defaults
_WORKER_CONTAINER_NAME=""
_WORKER_WATCHDOG_PID=""
_WORKER_SSH_PORT=""

show_help() {
    cat <<EOF
Join Subcommand E2E Test

Usage: $0 [OPTIONS]

Options:
  --distro <name>         Distribution to test (default: $DISTRO)
  --k8s-version <ver>     Kubernetes version (e.g., 1.32)
  --memory <MB>           VM memory (default: $VM_MEMORY)
  --cpus <count>          VM CPUs (default: $VM_CPUS)
  --disk-size <size>      VM disk size (default: $VM_DISK_SIZE)
  --help, -h              Show this help message
EOF
}

_copy_bundle_to_node() {
    local port="$1" label="$2" bundle="$3"
    log_info "[$label] Copying setup-k8s bundle..."
    scp "${SSH_OPTS[@]}" -P "$port" "$bundle" "root@localhost:/tmp/setup-k8s.sh" >/dev/null
    vm_ssh_root "$port" "chmod +x /tmp/setup-k8s.sh"
}

_join_cp_ssh() { vm_ssh_root "$_CP_SSH_PORT" "$@"; }
_join_worker_ssh() { vm_ssh_root "$_WORKER_SSH_PORT" "$@"; }

_extract_join_arg() {
    local join_cmd="$1" flag="$2"
    awk -v flag="$flag" '
      {
        for (i = 1; i <= NF; i++) {
          if ($i == flag && (i + 1) <= NF) {
            print $(i + 1)
            exit
          }
        }
      }
    ' <<< "$join_cmd"
}

run_join_test() {
    _test_preamble "join" "$DISTRO"
    local cp_container="k8s-join-cp-${DISTRO}-${_TEST_TS}"
    local worker_container="k8s-join-w-${DISTRO}-${_TEST_TS}"
    local log_file="$_TEST_LOG_FILE"

    log_info "VM resources: memory=${VM_MEMORY}MB cpus=${VM_CPUS} disk=${VM_DISK_SIZE}"
    log_info "Docker network: $DOCKER_NETWORK ($DOCKER_SUBNET)"
    log_info "CP: $CP_DOCKER_IP, Worker: $WORKER_DOCKER_IP"

    trap '_cleanup_cp_worker' EXIT INT TERM HUP

    resolve_k8s_version || return 1
    create_cp_worker_env "$cp_container" "$worker_container" "join-cp" "join-worker" "k8s-join-test" "k8s-join-test"

    local bundle
    bundle=$(mktemp /tmp/setup-k8s-join-bundle.XXXXXX.sh)
    _generate_bundle "$SETUP_K8S_SCRIPT" "$bundle" "all"
    _copy_bundle_to_node "$_CP_SSH_PORT" "CP" "$bundle"
    _copy_bundle_to_node "$_WORKER_SSH_PORT" "Worker" "$bundle"
    rm -f "$bundle"

    log_info "=== Phase 1: init control-plane ==="
    local init_cmd
    init_cmd="bash /tmp/setup-k8s.sh init --kubernetes-version $(printf '%q' "$K8S_VERSION") --control-plane-endpoint $(printf '%q' "${CP_DOCKER_IP}:6443")"
    vm_ssh_root "$_CP_SSH_PORT" "nohup bash -c '$init_cmd > /tmp/setup-k8s-init.log 2>&1; echo \$? > /tmp/init-exit-code' </dev/null >/dev/null 2>&1 &"
    if ! poll_vm_command _join_cp_ssh "$cp_container" /tmp/init-exit-code /tmp/setup-k8s-init.log "$TIMEOUT_TOTAL"; then
        vm_ssh_root "$_CP_SSH_PORT" "cat /tmp/setup-k8s-init.log" 2>/dev/null || true
        _cleanup_cp_worker
        trap - EXIT INT TERM HUP
        return 1
    fi
    local init_exit="$POLL_EXIT_CODE"
    log_info "Init exit code: $init_exit"
    if [ "$init_exit" -ne 0 ]; then
        vm_ssh_root "$_CP_SSH_PORT" "cat /tmp/setup-k8s-init.log" 2>/dev/null || true
        _cleanup_cp_worker
        trap - EXIT INT TERM HUP
        return 1
    fi

    log_info "=== Phase 2: extract join information ==="
    local join_cmd join_address join_token discovery_hash
    join_cmd=$(vm_ssh_root "$_CP_SSH_PORT" "kubeadm token create --print-join-command" | tr -d '\r')
    join_address=$(awk '{print $3}' <<< "$join_cmd")
    join_token=$(_extract_join_arg "$join_cmd" "--token")
    discovery_hash=$(_extract_join_arg "$join_cmd" "--discovery-token-ca-cert-hash")
    if [ -z "$join_address" ] || [ -z "$join_token" ] || [ -z "$discovery_hash" ]; then
        log_error "Failed to parse join command: $join_cmd"
        _cleanup_cp_worker
        trap - EXIT INT TERM HUP
        return 1
    fi

    log_info "=== Phase 3: join worker ==="
    local worker_join_cmd
    worker_join_cmd="bash /tmp/setup-k8s.sh join --kubernetes-version $(printf '%q' "$K8S_VERSION") --join-address $(printf '%q' "$join_address") --join-token $(printf '%q' "$join_token") --discovery-token-hash $(printf '%q' "$discovery_hash")"
    vm_ssh_root "$_WORKER_SSH_PORT" "nohup bash -c '$worker_join_cmd > /tmp/setup-k8s-join.log 2>&1; echo \$? > /tmp/join-exit-code' </dev/null >/dev/null 2>&1 &"
    if ! poll_vm_command _join_worker_ssh "$worker_container" /tmp/join-exit-code /tmp/setup-k8s-join.log "$TIMEOUT_TOTAL"; then
        vm_ssh_root "$_WORKER_SSH_PORT" "cat /tmp/setup-k8s-join.log" 2>/dev/null || true
        _cleanup_cp_worker
        trap - EXIT INT TERM HUP
        return 1
    fi
    local join_exit="$POLL_EXIT_CODE"
    log_info "Join exit code: $join_exit"

    log_info "=== Phase 4: verification ==="
    local all_pass=true
    [ "$init_exit" -eq 0 ] || all_pass=false
    [ "$join_exit" -eq 0 ] || all_pass=false

    local node_count
    node_count=$(vm_ssh_root "$_CP_SSH_PORT" "kubectl get nodes --no-headers --kubeconfig=/etc/kubernetes/admin.conf 2>/dev/null | wc -l" | tr -d '[:space:]') || node_count=0
    if [ "$node_count" -eq 2 ]; then
        log_success "CHECK: node count = 2"
    else
        log_error "CHECK: node count = $node_count (expected 2)"
        all_pass=false
    fi

    if vm_ssh_root "$_WORKER_SSH_PORT" "systemctl is-active kubelet | grep -qx active" >/dev/null 2>&1; then
        log_success "CHECK: worker kubelet active"
    else
        log_error "CHECK: worker kubelet not active"
        all_pass=false
    fi

    vm_ssh_root "$_CP_SSH_PORT" "kubectl get nodes -o wide --kubeconfig=/etc/kubernetes/admin.conf" 2>/dev/null || true
    _test_result "JOIN" "$all_pass" _cleanup_cp_worker "$cp_container" "$_CP_SSH_PORT"
}

while [[ $# -gt 0 ]]; do
    if _parse_common_test_args "$@"; then shift "$SHIFT_COUNT"; continue; fi
    case $1 in
        --help|-h) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

if run_join_test; then
    exit 0
else
    exit 1
fi
