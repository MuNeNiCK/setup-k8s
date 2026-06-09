#!/bin/bash
#
# Upgrade Subcommand E2E Test via docker-vm-runner
# Usage: ./test/scenarios/upgrade.sh [--distro <name>] [--from-version <ver>] [--to-version <ver>]
#
# Scenario: Deploy cluster with --from-version, then upgrade to --to-version
#
# Tests:
#   1. deploy completes successfully (exit 0)
#   2. upgrade completes successfully (exit 0)
#   3. CP: kubeadm version matches target
#   4. CP: kubelet version matches target
#   5. Worker: kubelet version matches target
#   6. CP: kubectl get nodes responds
#   7. Node count = 2

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
FROM_VERSION=""  # MAJOR.MINOR for deploy (e.g., 1.32)
TO_VERSION=""    # MAJOR.MINOR.PATCH for upgrade (e.g., 1.33.2)
UPGRADE_EXTRA_ARGS=()
# Common defaults from vm_harness.sh: VM_MEMORY, VM_CPUS, VM_DISK_SIZE, TIMEOUT_TOTAL, SSH_READY_TIMEOUT

# Docker network
DOCKER_NETWORK="${DOCKER_NETWORK:-k8s-upgrade-net-$$}"
DOCKER_SUBNET="${DOCKER_SUBNET:-10.203.0.0/24}"
CP_DOCKER_IP="${CP_DOCKER_IP:-10.203.0.10}"
WORKER_DOCKER_IP="${WORKER_DOCKER_IP:-10.203.0.20}"

# SSH settings & cleanup state
SSH_KEY_DIR=""
_init_test_defaults
_WORKER_CONTAINER_NAME=""
_WORKER_WATCHDOG_PID=""
_WORKER_SSH_PORT=""

show_help() {
    cat <<EOF
Upgrade Subcommand E2E Test

Usage: $0 [OPTIONS]

Options:
  --distro <name>         Distribution to test (default: $DISTRO)
  --from-version <ver>    Initial K8s version MAJOR.MINOR (e.g., 1.32)
  --to-version <ver>      Target K8s version MAJOR.MINOR.PATCH (e.g., 1.33.2)
  --upgrade-args ARGS     Extra args for setup-k8s.sh upgrade
  --memory <MB>           VM memory (default: $VM_MEMORY)
  --cpus <count>          VM CPUs (default: $VM_CPUS)
  --disk-size <size>      VM disk size (default: $VM_DISK_SIZE)
  --help, -h              Show this help message

If --from-version / --to-version are not specified, the script resolves the
latest stable version and upgrades from the previous minor version's latest patch.

Examples:
  $0                                                  # auto-detect versions
  $0 --from-version 1.32 --to-version 1.33.2          # explicit versions
  $0 --distro debian-12-cloud-amd64 --from-version 1.32 --to-version 1.33.2
EOF
}

# --- Version resolution ---

# Resolve FROM and TO versions automatically if not set.
# FROM = previous stable minor, TO = current stable latest patch
resolve_upgrade_versions() {
    if [ -n "$FROM_VERSION" ] && [ -n "$TO_VERSION" ]; then
        log_info "Using explicit versions: $FROM_VERSION -> $TO_VERSION"
        return 0
    fi

    log_info "Resolving Kubernetes versions for upgrade test..."
    local stable_txt
    if ! stable_txt=$(curl -fsSL --retry 3 --retry-delay 2 https://dl.k8s.io/release/stable.txt); then
        log_error "Failed to fetch stable Kubernetes version"
        return 1
    fi
    # stable_txt = e.g. "v1.33.2"
    if ! echo "$stable_txt" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+'; then
        log_error "Unexpected response from dl.k8s.io: $stable_txt"
        return 1
    fi

    local full_ver
    full_ver=$(echo "$stable_txt" | sed 's/^v//')
    local major minor patch
    major=$(echo "$full_ver" | cut -d. -f1)
    minor=$(echo "$full_ver" | cut -d. -f2)
    patch=$(echo "$full_ver" | cut -d. -f3)

    if [ -z "$TO_VERSION" ]; then
        TO_VERSION="${major}.${minor}.${patch}"
    fi

    if [ -z "$FROM_VERSION" ]; then
        local prev_minor=$((minor - 1))
        FROM_VERSION="${major}.${prev_minor}"
    fi

    log_success "Upgrade path: ${FROM_VERSION} -> ${TO_VERSION}"
}

# --- Main test logic ---

run_upgrade_test() {
    _test_preamble "upgrade" "$DISTRO"
    local cp_container="k8s-upgrade-cp-${DISTRO}-${_TEST_TS}"
    local worker_container="k8s-upgrade-w-${DISTRO}-${_TEST_TS}"
    local log_file="$_TEST_LOG_FILE"

    log_info "VM resources: memory=${VM_MEMORY}MB cpus=${VM_CPUS} disk=${VM_DISK_SIZE}"
    log_info "Docker network: $DOCKER_NETWORK ($DOCKER_SUBNET)"
    log_info "CP: $CP_DOCKER_IP, Worker: $WORKER_DOCKER_IP"

    trap '_cleanup_cp_worker' EXIT INT TERM HUP

    # --- Step 1: Resolve versions ---
    resolve_upgrade_versions || return 1
    log_info "Upgrade path: v${FROM_VERSION} -> v${TO_VERSION}"

    # --- Setup VM environment ---
    create_cp_worker_env "$cp_container" "$worker_container" "upgrade-cp" "upgrade-worker" "k8s-upgrade-test" "k8s-upgrade-test"

    # ===================================================================
    # Phase 1: Deploy cluster with FROM_VERSION
    # ===================================================================
    log_info "=== Phase 1: Deploy cluster with v${FROM_VERSION} ==="
    local deploy_cmd=(
        bash "$SETUP_K8S_SCRIPT" deploy
        --control-planes "$CP_DOCKER_IP"
        --workers "$WORKER_DOCKER_IP"
        --ssh-user root
        --ssh-port 2222
        --ssh-key "$SSH_KEY_DIR/id_test"
        --ssh-host-key-check accept-new
        --kubernetes-version "$FROM_VERSION"
        --control-plane-endpoint "${CP_DOCKER_IP}:6443"
    )
    log_info "Deploy command: ${deploy_cmd[*]}"

    local deploy_exit_code=0
    run_with_timeout deploy_exit_code "$log_file" "${deploy_cmd[@]}"

    if [ "$deploy_exit_code" -ne 0 ]; then
        log_error "Deploy failed with exit code $deploy_exit_code. Cannot proceed with upgrade test."
        return 1
    fi
    log_success "Phase 1: Deploy completed successfully"

    # Verify deploy baseline
    local pre_version
    pre_version=$(vm_ssh_root "$_CP_SSH_PORT" "kubeadm version -o short" 2>/dev/null | tr -d '[:space:]')
    log_info "Pre-upgrade kubeadm version: $pre_version"

    # ===================================================================
    # Phase 2: Run upgrade
    # ===================================================================
    log_info "=== Phase 2: Upgrade cluster to v${TO_VERSION} ==="
    local upgrade_cmd=(
        bash "$SETUP_K8S_SCRIPT" upgrade
        --control-planes "$CP_DOCKER_IP"
        --workers "$WORKER_DOCKER_IP"
        --ssh-user root
        --ssh-port 2222
        --ssh-key "$SSH_KEY_DIR/id_test"
        --ssh-host-key-check accept-new
        --kubernetes-version "$TO_VERSION"
    )
    if [ ${#UPGRADE_EXTRA_ARGS[@]} -gt 0 ]; then
        upgrade_cmd+=("${UPGRADE_EXTRA_ARGS[@]}")
    fi
    log_info "Upgrade command: ${upgrade_cmd[*]}"

    local upgrade_exit_code=0
    run_with_timeout upgrade_exit_code "$log_file" "${upgrade_cmd[@]}"

    # ===================================================================
    # Phase 3: Verification
    # ===================================================================
    log_info "=== Verification ==="

    local all_pass=true
    local target_minor
    target_minor=$(echo "$TO_VERSION" | cut -d. -f1,2)

    # Check 1: deploy exit code
    if [ "$deploy_exit_code" -eq 0 ]; then
        log_success "CHECK 1: deploy exit code = 0"
    else
        log_error "CHECK 1: deploy exit code = $deploy_exit_code"
        all_pass=false
    fi

    # Check 2: upgrade exit code
    if [ "$upgrade_exit_code" -eq 0 ]; then
        log_success "CHECK 2: upgrade exit code = 0"
    else
        log_error "CHECK 2: upgrade exit code = $upgrade_exit_code"
        all_pass=false
    fi

    # Check 3: CP kubeadm version contains target
    local cp_kubeadm_ver
    cp_kubeadm_ver=$(vm_ssh_root "$_CP_SSH_PORT" "kubeadm version -o short" 2>/dev/null | tr -d '[:space:]') || cp_kubeadm_ver="unknown"
    if echo "$cp_kubeadm_ver" | grep -q "v${target_minor}"; then
        log_success "CHECK 3: CP kubeadm version = $cp_kubeadm_ver (contains v${target_minor})"
    else
        log_error "CHECK 3: CP kubeadm version = $cp_kubeadm_ver (expected v${target_minor}.*)"
        all_pass=false
    fi

    # Check 4: CP kubelet version contains target
    local cp_kubelet_ver
    cp_kubelet_ver=$(vm_ssh_root "$_CP_SSH_PORT" "kubelet --version" 2>/dev/null | tr -d '[:space:]') || cp_kubelet_ver="unknown"
    if echo "$cp_kubelet_ver" | grep -q "v${target_minor}"; then
        log_success "CHECK 4: CP kubelet version = $cp_kubelet_ver (contains v${target_minor})"
    else
        log_error "CHECK 4: CP kubelet version = $cp_kubelet_ver (expected v${target_minor}.*)"
        all_pass=false
    fi

    # Check 5: Worker kubelet version contains target
    local worker_kubelet_ver
    worker_kubelet_ver=$(vm_ssh_root "$_WORKER_SSH_PORT" "kubelet --version" 2>/dev/null | tr -d '[:space:]') || worker_kubelet_ver="unknown"
    if echo "$worker_kubelet_ver" | grep -q "v${target_minor}"; then
        log_success "CHECK 5: Worker kubelet version = $worker_kubelet_ver (contains v${target_minor})"
    else
        log_error "CHECK 5: Worker kubelet version = $worker_kubelet_ver (expected v${target_minor}.*)"
        all_pass=false
    fi

    # Check 6: CP API server responsive
    if vm_ssh_root "$_CP_SSH_PORT" "timeout 30 kubectl get nodes --kubeconfig=/etc/kubernetes/admin.conf" >/dev/null 2>&1; then
        log_success "CHECK 6: CP API server responsive"
    else
        log_error "CHECK 6: CP API server NOT responsive"
        all_pass=false
    fi

    # Check 7: Node count = 2
    local node_count
    node_count=$(vm_ssh_root "$_CP_SSH_PORT" "kubectl get nodes --no-headers --kubeconfig=/etc/kubernetes/admin.conf 2>/dev/null | wc -l" 2>/dev/null | tr -d '[:space:]') || node_count="0"
    if [ "$node_count" -eq 2 ]; then
        log_success "CHECK 7: Node count = $node_count (expected 2)"
    else
        log_error "CHECK 7: Node count = $node_count (expected 2)"
        all_pass=false
    fi

    # Show node list
    log_info "Node status:"
    vm_ssh_root "$_CP_SSH_PORT" "kubectl get nodes -o wide --kubeconfig=/etc/kubernetes/admin.conf" 2>/dev/null || true

    # ===================================================================
    # Result
    # ===================================================================
    echo ""
    log_info "Log file: $log_file"
    _test_result "UPGRADE" "$all_pass" _cleanup_cp_worker "$cp_container" "$_CP_SSH_PORT"
}

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    if _parse_common_test_args "$@"; then shift "$SHIFT_COUNT"; continue; fi
    case $1 in
        --help|-h) show_help; exit 0 ;;
        --from-version) _require_arg $# "$1"; FROM_VERSION="$2"; shift 2 ;;
        --to-version) _require_arg $# "$1"; TO_VERSION="$2"; shift 2 ;;
        --upgrade-args)
            _require_arg $# "$1"
            read -r -a _upgrade_args_tmp <<< "$2"
            UPGRADE_EXTRA_ARGS+=("${_upgrade_args_tmp[@]}")
            shift 2
            ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

if run_upgrade_test; then
    exit 0
else
    exit 1
fi
