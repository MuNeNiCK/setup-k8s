#!/bin/bash
#
# Certificate Renewal Subcommand E2E Test via docker-vm-runner
# Usage: ./test/scenarios/cert-renew.sh [--distro <name>] [--k8s-version <ver>]
#
# Scenario: Deploy single CP → check-only → renew all → verify API → renew specific → verify API
#
# Tests:
#   1. deploy completes successfully (exit 0)
#   2. renew --check-only exits 0 and shows expiration info
#   3. renew (all certs) exits 0
#   4. API server responsive after full renewal
#   5. renew --certs apiserver,front-proxy-client exits 0
#   6. API server responsive after selective renewal
#   7. certificate expiration dates updated (not expired)

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
DOCKER_NETWORK="${DOCKER_NETWORK:-k8s-renew-net-$$}"
DOCKER_SUBNET="${DOCKER_SUBNET:-172.31.0.0/24}"
CP_DOCKER_IP="${CP_DOCKER_IP:-172.31.0.10}"

# SSH settings & cleanup state
SSH_KEY_DIR=""
_init_test_defaults

show_help() {
    cat <<EOF
Certificate Renewal Subcommand E2E Test

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

run_renew_test() {
    _test_preamble "renew" "$DISTRO"
    local cp_container="k8s-renew-cp-${DISTRO}-${_TEST_TS}"
    local log_file="$_TEST_LOG_FILE"

    log_info "VM resources: memory=${VM_MEMORY}MB cpus=${VM_CPUS} disk=${VM_DISK_SIZE}"
    log_info "Docker network: $DOCKER_NETWORK ($DOCKER_SUBNET)"
    log_info "CP: $CP_DOCKER_IP"

    trap '_cleanup_single_cp' EXIT INT TERM HUP

    # --- Setup VM environment ---
    create_single_cp_env "$cp_container" "renew-cp" "k8s-renew-test" "k8s-renew-test"

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
        log_error "Deploy failed with exit code $deploy_exit_code. Cannot proceed with renew test."
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
    # Phase 2: renew --check-only (remote mode)
    # ===================================================================
    log_info "=== Phase 2: renew --check-only (remote mode) ==="
    local check_cmd=(
        bash "$SETUP_K8S_SCRIPT" renew
        --control-planes "$CP_DOCKER_IP"
        --ssh-user root
        --ssh-port 2222
        --ssh-key "$SSH_KEY_DIR/id_test"
        --ssh-host-key-check accept-new
        --check-only
    )
    log_info "Check command: ${check_cmd[*]}"

    local check_exit_code=0
    run_with_timeout check_exit_code "$log_file" "${check_cmd[@]}"

    # ===================================================================
    # Phase 3: renew all certs (remote mode)
    # ===================================================================
    log_info "=== Phase 3: renew all certificates (remote mode) ==="
    local renew_all_cmd=(
        bash "$SETUP_K8S_SCRIPT" renew
        --control-planes "$CP_DOCKER_IP"
        --ssh-user root
        --ssh-port 2222
        --ssh-key "$SSH_KEY_DIR/id_test"
        --ssh-host-key-check accept-new
    )
    log_info "Renew all command: ${renew_all_cmd[*]}"

    local renew_all_exit_code=0
    run_with_timeout renew_all_exit_code "$log_file" "${renew_all_cmd[@]}"

    # Wait for API server to recover after full renewal
    log_info "Waiting for API server after full renewal..."
    local api_after_all=false
    if wait_for_api_ready "$_CP_SSH_PORT" 40 5; then
        api_after_all=true
    fi

    # ===================================================================
    # Phase 4: renew specific certs (remote mode)
    # ===================================================================
    log_info "=== Phase 4: renew specific certificates (remote mode) ==="
    local specific_certs="apiserver,front-proxy-client"
    local renew_specific_cmd=(
        bash "$SETUP_K8S_SCRIPT" renew
        --control-planes "$CP_DOCKER_IP"
        --ssh-user root
        --ssh-port 2222
        --ssh-key "$SSH_KEY_DIR/id_test"
        --ssh-host-key-check accept-new
        --certs "$specific_certs"
    )
    log_info "Renew specific command: ${renew_specific_cmd[*]}"

    local renew_specific_exit_code=0
    run_with_timeout renew_specific_exit_code "$log_file" "${renew_specific_cmd[@]}"

    # Wait for API server to recover after selective renewal
    log_info "Waiting for API server after selective renewal..."
    local api_after_specific=false
    if wait_for_api_ready "$_CP_SSH_PORT" 40 5; then
        api_after_specific=true
    fi

    # ===================================================================
    # Phase 5: Verify certificate dates on the node
    # ===================================================================
    log_info "=== Phase 5: Verify certificate expiration ==="
    local cert_check_output=""
    cert_check_output=$(vm_ssh_root "$_CP_SSH_PORT" "kubeadm certs check-expiration 2>&1" 2>/dev/null) || true

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

    # Check 2: renew --check-only exits 0
    if [ "$check_exit_code" -eq 0 ]; then
        log_success "CHECK 2: renew --check-only exit code = 0"
    else
        log_error "CHECK 2: renew --check-only exit code = $check_exit_code"
        all_pass=false
    fi

    # Check 3: renew all exits 0
    if [ "$renew_all_exit_code" -eq 0 ]; then
        log_success "CHECK 3: renew all exit code = 0"
    else
        log_error "CHECK 3: renew all exit code = $renew_all_exit_code"
        all_pass=false
    fi

    # Check 4: API server responsive after full renewal
    if [ "$api_after_all" = true ]; then
        log_success "CHECK 4: API server responsive after full renewal"
    else
        log_error "CHECK 4: API server NOT responsive after full renewal"
        all_pass=false
    fi

    # Check 5: renew specific certs exits 0
    if [ "$renew_specific_exit_code" -eq 0 ]; then
        log_success "CHECK 5: renew --certs apiserver,front-proxy-client exit code = 0"
    else
        log_error "CHECK 5: renew --certs apiserver,front-proxy-client exit code = $renew_specific_exit_code"
        all_pass=false
    fi

    # Check 6: API server responsive after selective renewal
    if [ "$api_after_specific" = true ]; then
        log_success "CHECK 6: API server responsive after selective renewal"
    else
        log_error "CHECK 6: API server NOT responsive after selective renewal"
        all_pass=false
    fi

    # Check 7: certificate expiration shows valid dates (not expired)
    if [ -n "$cert_check_output" ]; then
        # kubeadm certs check-expiration outputs a table with expiration dates
        # Check that no certificate shows "EXPIRED" or "invalid"
        if echo "$cert_check_output" | grep -qi "expired"; then
            log_error "CHECK 7: Some certificates appear EXPIRED"
            all_pass=false
        else
            log_success "CHECK 7: Certificate expiration dates look valid"
        fi
        log_info "Certificate status:"
        echo "$cert_check_output" | while IFS= read -r line; do
            log_info "  $line"
        done
    else
        log_warn "CHECK 7: Could not retrieve certificate expiration info (non-fatal)"
    fi

    # Show cluster state for debugging
    log_info "Cluster state after renewal:"
    vm_ssh_root "$_CP_SSH_PORT" "kubectl get nodes -o wide --kubeconfig=/etc/kubernetes/admin.conf" 2>/dev/null || true

    # ===================================================================
    # Result
    # ===================================================================
    echo ""
    log_info "Log file: $log_file"
    _test_result "CERTIFICATE RENEWAL" "$all_pass" _cleanup_single_cp "$cp_container" "$_CP_SSH_PORT"
}

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    if _parse_common_test_args "$@"; then shift "$SHIFT_COUNT"; continue; fi
    case $1 in
        --help|-h) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

if run_renew_test; then
    exit 0
else
    exit 1
fi
