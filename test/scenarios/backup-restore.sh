#!/bin/bash
#
# Backup/Restore Subcommand E2E Test via docker-vm-runner
# Usage: ./test/scenarios/backup-restore.sh [--distro <name>] [--k8s-version <ver>]
#
# Scenario: Deploy single CP → backup etcd → write data → restore → verify data restored
#
# Tests:
#   1. deploy completes successfully (exit 0)
#   2. backup (remote) completes successfully (exit 0)
#   3. snapshot file exists and is non-trivial (>100 bytes)
#   4. restore (remote) completes successfully (exit 0)
#   5. pre-backup configmap exists after restore
#   6. post-backup configmap is gone after restore
#   7. CP API server responsive after restore

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
# Common defaults from vm_harness.sh: VM_MEMORY, VM_CPUS, VM_DISK_SIZE, TIMEOUT_TOTAL, SSH_READY_TIMEOUT

# Docker network
DOCKER_NETWORK="${DOCKER_NETWORK:-k8s-backup-net-$$}"
DOCKER_SUBNET="${DOCKER_SUBNET:-172.30.0.0/24}"
CP_DOCKER_IP="${CP_DOCKER_IP:-172.30.0.10}"

# SSH settings & cleanup state
SSH_KEY_DIR=""
_init_test_defaults

show_help() {
    cat <<EOF
Backup/Restore Subcommand E2E Test

Usage: $0 [OPTIONS]

Options:
  --distro <name>         Distribution to test (default: $DISTRO)
  --k8s-version <ver>     Kubernetes version (e.g., 1.32)
  --memory <MB>           VM memory (default: $VM_MEMORY)
  --cpus <count>          VM CPUs (default: $VM_CPUS)
  --disk-size <size>      VM disk size (default: $VM_DISK_SIZE)
  --help, -h              Show this help message

Examples:
  $0                                        # auto-detect version
  $0 --distro debian-12-cloud-amd64 --k8s-version 1.32
EOF
}

# --- Main test logic ---

wait_for_configmap_present() {
    local name="$1" timeout="${2:-60}" interval="${3:-3}"
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        if vm_ssh_root "$_CP_SSH_PORT" \
            "kubectl get configmap '$name' --kubeconfig=/etc/kubernetes/admin.conf" >/dev/null 2>&1; then
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    return 1
}

wait_for_configmap_absent() {
    local name="$1" timeout="${2:-60}" interval="${3:-3}"
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        if ! vm_ssh_root "$_CP_SSH_PORT" \
            "kubectl get configmap '$name' --kubeconfig=/etc/kubernetes/admin.conf" >/dev/null 2>&1 && \
           ! vm_ssh_root "$_CP_SSH_PORT" \
            "kubectl get configmaps --no-headers --kubeconfig=/etc/kubernetes/admin.conf | awk -v n='$name' '\$1 == n {found=1} END {exit found ? 0 : 1}'" >/dev/null 2>&1; then
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    return 1
}

run_backup_test() {
    _test_preamble "backup" "$DISTRO"
    local cp_container="k8s-backup-cp-${DISTRO}-${_TEST_TS}"
    local log_file="$_TEST_LOG_FILE"

    log_info "VM resources: memory=${VM_MEMORY}MB cpus=${VM_CPUS} disk=${VM_DISK_SIZE}"
    log_info "Docker network: $DOCKER_NETWORK ($DOCKER_SUBNET)"
    log_info "CP: $CP_DOCKER_IP"

    trap '_cleanup_single_cp' EXIT INT TERM HUP

    # --- Setup VM environment ---
    create_single_cp_env "$cp_container" "backup-cp" "k8s-backup-test" "k8s-backup-test"

    # --- Resolve K8s version ---
    resolve_k8s_version || return 1

    # ===================================================================
    # Phase 1: Deploy single-node cluster
    # ===================================================================
    log_info "=== Phase 1: Deploy single-node cluster ==="
    local deploy_cmd=(
        bash "$SETUP_K8S_SCRIPT" deploy
        --control-planes "$CP_DOCKER_IP"
        --ssh-user root
        --ssh-port 2222
        --ssh-key "$SSH_KEY_DIR/id_test"
        --ssh-host-key-check accept-new
        --kubernetes-version "$K8S_VERSION"
        --control-plane-endpoint "${CP_DOCKER_IP}:6443"
    )
    log_info "Deploy command: ${deploy_cmd[*]}"

    local deploy_exit_code=0
    run_with_timeout deploy_exit_code "$log_file" "${deploy_cmd[@]}"

    if [ "$deploy_exit_code" -ne 0 ]; then
        log_error "Deploy failed with exit code $deploy_exit_code. Cannot proceed with backup test."
        return 1
    fi
    log_success "Phase 1: Deploy completed successfully"

    # Wait for API server to be stable
    log_info "Waiting for API server to stabilize..."
    if ! wait_for_api_ready "$_CP_SSH_PORT" 20 5; then
        log_error "API server did not become ready"
        return 1
    fi

    # ===================================================================
    # Phase 2: Create pre-backup data
    # ===================================================================
    log_info "=== Phase 2: Create pre-backup test data ==="
    vm_ssh_root "$_CP_SSH_PORT" \
        "kubectl create configmap pre-backup-data --from-literal=test=before-backup --kubeconfig=/etc/kubernetes/admin.conf" 2>&1 || true
    log_info "Created configmap 'pre-backup-data'"

    # Verify pre-backup data exists
    if vm_ssh_root "$_CP_SSH_PORT" \
        "kubectl get configmap pre-backup-data --kubeconfig=/etc/kubernetes/admin.conf" >/dev/null 2>&1; then
        log_success "Pre-backup configmap verified"
    else
        log_error "Failed to create pre-backup configmap"
        return 1
    fi

    # ===================================================================
    # Phase 3: Backup etcd (remote mode)
    # ===================================================================
    log_info "=== Phase 3: Backup etcd (remote mode) ==="
    local snapshot_path="/tmp/etcd-backup-test-${_TEST_TS}.db"
    local backup_cmd=(
        bash "$SETUP_K8S_SCRIPT" backup
        --control-planes "$CP_DOCKER_IP"
        --ssh-user root
        --ssh-port 2222
        --ssh-key "$SSH_KEY_DIR/id_test"
        --ssh-host-key-check accept-new
        --snapshot-path "$snapshot_path"
    )
    log_info "Backup command: ${backup_cmd[*]}"

    local backup_exit_code=0
    run_with_timeout backup_exit_code "$log_file" "${backup_cmd[@]}"

    # ===================================================================
    # Phase 4: Write post-backup data (should disappear after restore)
    # ===================================================================
    log_info "=== Phase 4: Create post-backup test data ==="
    vm_ssh_root "$_CP_SSH_PORT" \
        "kubectl create configmap post-backup-data --from-literal=test=after-backup --kubeconfig=/etc/kubernetes/admin.conf" 2>&1 || true
    log_info "Created configmap 'post-backup-data'"

    # Verify post-backup data exists
    if vm_ssh_root "$_CP_SSH_PORT" \
        "kubectl get configmap post-backup-data --kubeconfig=/etc/kubernetes/admin.conf" >/dev/null 2>&1; then
        log_success "Post-backup configmap verified"
    else
        log_warn "Failed to create post-backup configmap (non-fatal)"
    fi

    # ===================================================================
    # Phase 5: Restore etcd (remote mode)
    # ===================================================================
    log_info "=== Phase 5: Restore etcd (remote mode) ==="
    local restore_cmd=(
        bash "$SETUP_K8S_SCRIPT" restore
        --control-planes "$CP_DOCKER_IP"
        --ssh-user root
        --ssh-port 2222
        --ssh-key "$SSH_KEY_DIR/id_test"
        --ssh-host-key-check accept-new
        --snapshot-path "$snapshot_path"
    )
    log_info "Restore command: ${restore_cmd[*]}"

    local restore_exit_code=0
    run_with_timeout restore_exit_code "$log_file" "${restore_cmd[@]}"

    # Wait for API server to recover after restore
    log_info "Waiting for API server to recover after restore..."
    local restore_api_ready=false
    if wait_for_api_ready "$_CP_SSH_PORT" 40 5; then
        restore_api_ready=true
    fi

    # ===================================================================
    # Verification
    # ===================================================================
    log_info "=== Verification ==="

    local all_pass=true

    # Check 1: deploy exit code = 0
    if [ "$deploy_exit_code" -eq 0 ]; then
        log_success "CHECK 1: deploy exit code = 0"
    else
        log_error "CHECK 1: deploy exit code = $deploy_exit_code"
        all_pass=false
    fi

    # Check 2: backup exit code = 0
    if [ "$backup_exit_code" -eq 0 ]; then
        log_success "CHECK 2: backup exit code = 0"
    else
        log_error "CHECK 2: backup exit code = $backup_exit_code"
        all_pass=false
    fi

    # Check 3: snapshot file exists and is non-trivial
    if [ -f "$snapshot_path" ]; then
        local snap_size
        snap_size=$(wc -c < "$snapshot_path")
        if [ "$snap_size" -gt 100 ]; then
            log_success "CHECK 3: snapshot file exists ($snap_size bytes)"
        else
            log_error "CHECK 3: snapshot file too small ($snap_size bytes)"
            all_pass=false
        fi
    else
        log_error "CHECK 3: snapshot file not found: $snapshot_path"
        all_pass=false
    fi

    # Check 4: restore exit code = 0
    if [ "$restore_exit_code" -eq 0 ]; then
        log_success "CHECK 4: restore exit code = 0"
    else
        log_error "CHECK 4: restore exit code = $restore_exit_code"
        all_pass=false
    fi

    # Check 5: pre-backup configmap exists after restore
    if [ "$restore_api_ready" = true ]; then
        if wait_for_configmap_present "pre-backup-data" 60 3; then
            log_success "CHECK 5: pre-backup configmap exists after restore"
        else
            log_error "CHECK 5: pre-backup configmap NOT found after restore"
            all_pass=false
        fi
    else
        log_error "CHECK 5: API server not ready, cannot verify pre-backup data"
        all_pass=false
    fi

    # Check 6: post-backup configmap is gone after restore
    if [ "$restore_api_ready" = true ]; then
        if wait_for_configmap_absent "post-backup-data" 60 3; then
            log_success "CHECK 6: post-backup configmap correctly absent after restore"
        else
            log_error "CHECK 6: post-backup configmap still exists (should be gone after restore)"
            all_pass=false
        fi
    else
        log_error "CHECK 6: API server not ready, cannot verify post-backup data"
        all_pass=false
    fi

    # Check 7: CP API server responsive after restore
    if [ "$restore_api_ready" = true ]; then
        log_success "CHECK 7: CP API server responsive after restore"
    else
        log_error "CHECK 7: CP API server NOT responsive after restore"
        all_pass=false
    fi

    # Show cluster state for debugging
    log_info "Cluster state after restore:"
    vm_ssh_root "$_CP_SSH_PORT" "kubectl get nodes -o wide --kubeconfig=/etc/kubernetes/admin.conf" 2>/dev/null || true
    vm_ssh_root "$_CP_SSH_PORT" "kubectl get configmaps --kubeconfig=/etc/kubernetes/admin.conf" 2>/dev/null || true

    # Clean up snapshot
    rm -f "$snapshot_path"

    # ===================================================================
    # Result
    # ===================================================================
    echo ""
    log_info "Log file: $log_file"
    _test_result "BACKUP/RESTORE" "$all_pass" _cleanup_single_cp "$cp_container" "$_CP_SSH_PORT"
}

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    if _parse_common_test_args "$@"; then shift "$SHIFT_COUNT"; continue; fi
    case $1 in
        --help|-h) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

if run_backup_test; then
    exit 0
else
    exit 1
fi
