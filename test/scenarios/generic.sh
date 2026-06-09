#!/bin/bash
#
# Generic Distro (Binary Download) E2E Test via docker-vm-runner
# Usage: ./test/scenarios/generic.sh [OPTIONS]
#
# Tests the --distro generic path on a real VM:
#   1. setup-k8s.sh init --distro generic completes successfully
#   2. K8s binaries installed in /usr/local/bin/
#   3. kubelet service is active
#   4. API server responds to kubectl get nodes
#   5. setup-k8s.sh cleanup --distro generic removes binaries and service files
#   6. Binaries in /usr/local/bin/ are removed after cleanup
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
# cleanup is now integrated into setup-k8s.sh as the 'cleanup' subcommand
DOCKER_VM_RUNNER_IMAGE="${DOCKER_VM_RUNNER_IMAGE:-ghcr.io/munenick/docker-vm-runner:latest}"
VM_DATA_DIR="${VM_DATA_DIR:-$SCRIPT_DIR/data}"

# Defaults — use a well-known VM distro as host, but force generic path
HOST_DISTRO="${HOST_DISTRO:-ubuntu-24.04-cloud-amd64}"
K8S_VERSION=""
SETUP_EXTRA_ARGS=()
VM_MEMORY="${VM_MEMORY:-8192}"
VM_CPUS="${VM_CPUS:-4}"
VM_DISK_SIZE="${VM_DISK_SIZE:-40G}"
VM_BOOT_MODE="${VM_BOOT_MODE:-}"

TIMEOUT_TOTAL=1200
SSH_READY_TIMEOUT=300
LOGIN_USER="user"

SSH_KEY_DIR=""
SSH_PORT=""
SSH_BASE_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
# shellcheck disable=SC2034 # SSH_OPTS is used by vm_ssh/vm_scp in vm_harness.sh
SSH_OPTS=("${SSH_BASE_OPTS[@]}")

# Global cleanup state
_VM_CONTAINER_NAME=""
_WATCHDOG_PID=""
_SETUP_BUNDLE=""
_CLOUD_INIT_USER_DATA=""

_generic_cleanup() {
    _cleanup_vm_container "$_WATCHDOG_PID" "$_VM_CONTAINER_NAME"
    _WATCHDOG_PID=""
    _VM_CONTAINER_NAME=""
    cleanup_ssh_key
    rm -f "$_SETUP_BUNDLE" "$_CLOUD_INIT_USER_DATA"
}

show_help() {
    cat <<EOF
Generic Distro (Binary Download) E2E Test

Usage: $0 [OPTIONS]

Options:
  --host-distro DISTRO    VM distro to use as test host (default: $HOST_DISTRO)
  --k8s-version VER       Kubernetes minor version (e.g., 1.32)
  --setup-args ARGS       Extra args for setup-k8s.sh
  --memory MB             VM memory in MB (default: $VM_MEMORY)
  --cpus N                VM CPU count (default: $VM_CPUS)
  --disk-size SIZE        VM disk size (default: $VM_DISK_SIZE)
  --boot-mode MODE        VM boot mode: uefi or legacy (default: uefi)
  --help, -h              Show this help message

Example:
  $0                                           # Test generic on ubuntu-24.04-cloud-amd64
  $0 --host-distro debian-12-cloud-amd64                   # Test generic on debian-12-cloud-amd64
  $0 --k8s-version 1.32                        # Test with specific K8s version
  $0 --host-distro alpine-3.23-cloud-amd64     # Test on Alpine
EOF
}

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                show_help
                exit 0
                ;;
            --host-distro)
                _require_arg $# "$1"
                HOST_DISTRO="$2"
                shift 2
                ;;
            --k8s-version)
                _require_arg $# "$1"
                K8S_VERSION="$2"
                shift 2
                ;;
            --setup-args)
                _require_arg $# "$1"
                read -r -a _setup_args_tmp <<< "$2"
                SETUP_EXTRA_ARGS+=("${_setup_args_tmp[@]}")
                shift 2
                ;;
            --memory)
                _require_arg $# "$1"
                VM_MEMORY="$2"
                shift 2
                ;;
            --cpus)
                _require_arg $# "$1"
                VM_CPUS="$2"
                shift 2
                ;;
            --disk-size)
                _require_arg $# "$1"
                VM_DISK_SIZE="$2"
                shift 2
                ;;
            --boot-mode)
                _require_arg $# "$1"
                VM_BOOT_MODE="$2"
                shift 2
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

run_test() {
    local container_name
    container_name="k8s-generic-${HOST_DISTRO}-$(date +%s)"
    local log_file
    log_file="results/logs/generic-${HOST_DISTRO}-$(date +%Y%m%d-%H%M%S).log"

    mkdir -p results/logs

    log_info "=== Generic Distro E2E Test ==="
    log_info "Host distro: $HOST_DISTRO"
    log_info "Test path: --distro generic (binary download)"
    [ -n "$K8S_VERSION" ] && log_info "K8s version: $K8S_VERSION"
    log_info "VM resources: memory=${VM_MEMORY}MB cpus=${VM_CPUS} disk=${VM_DISK_SIZE}"
    test_validate_runner_distro "$HOST_DISTRO" || return 1

    # Clean up orphaned containers
    cleanup_orphaned_containers "k8s-test-runner"

    _VM_CONTAINER_NAME=""
    trap '_generic_cleanup' EXIT INT TERM HUP

    # SSH key
    setup_ssh_key
    SSH_PORT=$(find_free_port)

    # Start VM
    # Generate cloud-init user-data to ensure bash and sudo are present.
    # Distros like Alpine ship with ash/doas instead of bash/sudo, which
    # setup-k8s.sh (bash script) and the test harness (sudo) both require.
    _CLOUD_INIT_USER_DATA=$(mktemp /tmp/cloud-init-userdata.XXXXXX.yaml)
    cat > "$_CLOUD_INIT_USER_DATA" <<'CIEOF'
#cloud-config
packages:
  - bash
  - sudo
  - openssh
runcmd:
  - ["sh", "-c", "rc-update add sshd default && rc-service sshd start"]
CIEOF

    log_info "Starting VM container: $container_name (SSH port: $SSH_PORT)"
    local _docker_run_args=(
        docker run -d --rm
        --name "$container_name"
        --label "managed-by=k8s-test-runner"
        --device /dev/kvm:/dev/kvm
        -v "$VM_DATA_DIR:/data"
        -v "$_CLOUD_INIT_USER_DATA:/cloud-init-userdata.yaml:ro"
        -p "${SSH_PORT}:2222"
        -e "DISTRO=$HOST_DISTRO"
        -e "GUEST_NAME=$container_name"
        -e "SSH_PUBKEY=$(cat "$SSH_KEY_DIR/id_test.pub")"
        -e "CLOUD_INIT_USER_DATA=/cloud-init-userdata.yaml"
        -e "NO_CONSOLE=1"
        -e "MEMORY=$VM_MEMORY"
        -e "CPUS=$VM_CPUS"
        -e "DISK_SIZE=$VM_DISK_SIZE"
    )
    [ -n "$VM_BOOT_MODE" ] && _docker_run_args+=(-e "BOOT_MODE=$VM_BOOT_MODE")
    _docker_run_args+=("$DOCKER_VM_RUNNER_IMAGE")
    "${_docker_run_args[@]}" >/dev/null
    _VM_CONTAINER_NAME="$container_name"
    _WATCHDOG_PID=$(_start_vm_container_watchdog "$$" "$container_name")
    log_success "Container started"

    # Wait for cloud-init and SSH
    wait_for_cloud_init "$container_name" "$SSH_READY_TIMEOUT" "$HOST_DISTRO" || return 1
    wait_for_ssh "$SSH_PORT" "$LOGIN_USER" "$SSH_READY_TIMEOUT" "$HOST_DISTRO" || return 1
    wait_for_guest_bootstrap "$SSH_PORT" "$LOGIN_USER" "$SSH_READY_TIMEOUT" "$HOST_DISTRO" || return 1

    # Generate and transfer bundled scripts
    # Save K8S_VERSION: _generate_bundle sources variables.sh which resets it
    local _saved_k8s_version="$K8S_VERSION"
    _SETUP_BUNDLE=$(mktemp /tmp/setup-k8s-generic-bundle.XXXXXX.sh)
    log_info "Generating bundled script..."
    _generate_bundle "$SETUP_K8S_SCRIPT" "$_SETUP_BUNDLE" "all"
    K8S_VERSION="$_saved_k8s_version"
    log_info "Transferring bundled script to VM..."
    vm_scp "$_SETUP_BUNDLE" "/tmp/setup-k8s.sh"
    vm_ssh "chmod +x /tmp/setup-k8s.sh" >/dev/null 2>&1
    rm -f "$_SETUP_BUNDLE"
    _SETUP_BUNDLE=""
    log_success "Bundled script deployed to VM"

    # === Phase 1: Setup with --distro generic ===
    log_info "Phase 1: Running setup-k8s.sh init --distro generic ..."
    local setup_args="init --distro generic"
    if [ -n "$K8S_VERSION" ]; then
        setup_args+=" --kubernetes-version $(printf '%q' "$K8S_VERSION")"
    fi
    local extra_str=""
    if [ ${#SETUP_EXTRA_ARGS[@]} -gt 0 ]; then
        extra_str=$(printf '%q ' "${SETUP_EXTRA_ARGS[@]}")
        setup_args+=" $extra_str"
    fi

    local setup_cmd="bash /tmp/setup-k8s.sh ${setup_args} > /tmp/setup-k8s.log 2>&1; echo \$? > /tmp/setup-exit-code"
    vm_ssh "nohup bash -c '${setup_cmd}' </dev/null >/dev/null 2>&1 &"

    if ! poll_vm_command vm_ssh "$container_name" /tmp/setup-exit-code /tmp/setup-k8s.log "$TIMEOUT_TOTAL"; then
        vm_ssh "cat /tmp/setup-k8s.log" > "$log_file" 2>/dev/null || true
        log_error "Setup polling failed"
        return 1
    fi
    local setup_exit_code="$POLL_EXIT_CODE"
    log_info "Setup exit code: $setup_exit_code"

    if [ "$setup_exit_code" -ne 0 ]; then
        log_error "=== SETUP ERROR LOG ==="
        vm_ssh "cat /tmp/setup-k8s.log" 2>/dev/null || true
        log_error "=== END ==="
        return 1
    fi

    # === Phase 2: Verify Setup ===
    log_info "Phase 2: Verifying setup..."
    local test_passed=true

    # 2a. Binaries in /usr/local/bin/
    for bin in kubeadm kubelet kubectl; do
        if vm_ssh "test -x /usr/local/bin/$bin" >/dev/null 2>&1; then
            log_success "  /usr/local/bin/$bin exists"
        else
            log_error "  /usr/local/bin/$bin NOT found"
            test_passed=false
        fi
    done

    # 2b. kubelet service is active (init-system aware)
    local kubelet_active=false
    if vm_ssh "test -x /usr/bin/systemctl || test -x /bin/systemctl" >/dev/null 2>&1; then
        # systemd
        if vm_ssh "systemctl is-active kubelet" >/dev/null 2>&1; then
            kubelet_active=true
            log_success "  kubelet is active (systemd)"
        else
            log_error "  kubelet is NOT active (systemd)"
            test_passed=false
        fi
        # 2c. kubelet service file
        if vm_ssh "test -f /etc/systemd/system/kubelet.service" >/dev/null 2>&1; then
            log_success "  /etc/systemd/system/kubelet.service exists"
        else
            log_error "  /etc/systemd/system/kubelet.service NOT found"
            test_passed=false
        fi
        # 2d. kubeadm drop-in
        if vm_ssh "test -f /etc/systemd/system/kubelet.service.d/10-kubeadm.conf" >/dev/null 2>&1; then
            log_success "  kubelet drop-in 10-kubeadm.conf exists"
        else
            log_error "  kubelet drop-in 10-kubeadm.conf NOT found"
            test_passed=false
        fi
    elif vm_ssh "test -x /sbin/rc-service || test -x /usr/sbin/rc-service" >/dev/null 2>&1; then
        # OpenRC
        if vm_ssh "rc-service kubelet status" >/dev/null 2>&1; then
            kubelet_active=true
            log_success "  kubelet is active (openrc)"
        else
            log_error "  kubelet is NOT active (openrc)"
            test_passed=false
        fi
        # 2c. kubelet init script
        if vm_ssh "test -x /etc/init.d/kubelet" >/dev/null 2>&1; then
            log_success "  /etc/init.d/kubelet exists"
        else
            log_error "  /etc/init.d/kubelet NOT found"
            test_passed=false
        fi
    else
        log_error "  Unknown init system — cannot verify kubelet service"
        test_passed=false
    fi

    # 2e. CNI plugins
    if vm_ssh "test -d /opt/cni/bin && ls /opt/cni/bin/ | head -1 | grep -q ." >/dev/null 2>&1; then
        log_success "  /opt/cni/bin/ has plugins"
    else
        log_error "  /opt/cni/bin/ is empty or missing"
        test_passed=false
    fi

    # 2f. kubeconfig
    if vm_ssh "test -f /etc/kubernetes/admin.conf" >/dev/null 2>&1; then
        log_success "  /etc/kubernetes/admin.conf exists"
    else
        log_error "  /etc/kubernetes/admin.conf NOT found"
        test_passed=false
    fi

    # 2g. API server responsive
    local api_responsive=false
    if vm_ssh "PATH=/usr/local/bin:\$PATH timeout 30 kubectl get nodes --kubeconfig=/etc/kubernetes/admin.conf" >/dev/null 2>&1; then
        api_responsive=true
        log_success "  API server is responsive"
    else
        log_error "  API server is NOT responsive"
        test_passed=false
    fi

    if [ "$test_passed" = true ]; then
        log_success "Phase 2: Setup verification PASSED"
    else
        log_error "Phase 2: Setup verification FAILED"
        vm_ssh "cat /tmp/setup-k8s.log" > "$log_file" 2>/dev/null || true
        return 1
    fi

    # === Phase 3: Cleanup with --distro generic ===
    log_info "Phase 3: Running setup-k8s.sh cleanup --force --distro generic ..."
    local cleanup_cmd="bash /tmp/setup-k8s.sh cleanup --force --distro generic > /tmp/cleanup-k8s.log 2>&1; echo \$? > /tmp/cleanup-exit-code"
    vm_ssh "nohup bash -c '${cleanup_cmd}' </dev/null >/dev/null 2>&1 &"

    if ! poll_vm_command vm_ssh "$container_name" /tmp/cleanup-exit-code /tmp/cleanup-k8s.log "$TIMEOUT_TOTAL"; then
        log_warn "Cleanup polling failed"
    fi
    local cleanup_exit_code="$POLL_EXIT_CODE"
    log_info "Cleanup exit code: $cleanup_exit_code"

    # === Phase 4: Verify Cleanup ===
    log_info "Phase 4: Verifying cleanup..."
    local cleanup_passed=true

    # 4a. K8s binaries removed from /usr/local/bin/
    for bin in kubeadm kubelet kubectl; do
        if vm_ssh "test -f /usr/local/bin/$bin" >/dev/null 2>&1; then
            log_error "  /usr/local/bin/$bin still exists"
            cleanup_passed=false
        else
            log_success "  /usr/local/bin/$bin removed"
        fi
    done

    # 4b. kubelet service stopped (init-system aware)
    if vm_ssh "test -x /usr/bin/systemctl || test -x /bin/systemctl" >/dev/null 2>&1; then
        local kubelet_still_active
        kubelet_still_active=$(vm_ssh "systemctl is-active kubelet" 2>/dev/null) || kubelet_still_active="inactive"
        kubelet_still_active=$(echo "$kubelet_still_active" | tr -d '[:space:]')
        if [ "$kubelet_still_active" = "active" ]; then
            log_error "  kubelet is still active after cleanup"
            cleanup_passed=false
        else
            log_success "  kubelet service stopped"
        fi
        # 4c. kubelet service file removed
        if vm_ssh "test -f /etc/systemd/system/kubelet.service" >/dev/null 2>&1; then
            log_error "  /etc/systemd/system/kubelet.service still exists"
            cleanup_passed=false
        else
            log_success "  kubelet.service removed"
        fi
    elif vm_ssh "test -x /sbin/rc-service || test -x /usr/sbin/rc-service" >/dev/null 2>&1; then
        if vm_ssh "rc-service kubelet status" >/dev/null 2>&1; then
            log_error "  kubelet is still active after cleanup (openrc)"
            cleanup_passed=false
        else
            log_success "  kubelet service stopped (openrc)"
        fi
        # 4c. kubelet init script removed
        if vm_ssh "test -f /etc/init.d/kubelet" >/dev/null 2>&1; then
            log_error "  /etc/init.d/kubelet still exists"
            cleanup_passed=false
        else
            log_success "  kubelet init script removed"
        fi
    fi

    # 4d. /etc/kubernetes cleaned
    if vm_ssh "test -d /etc/kubernetes && ls -A /etc/kubernetes 2>/dev/null | head -1 | grep -q ." >/dev/null 2>&1; then
        log_error "  /etc/kubernetes still has files"
        cleanup_passed=false
    else
        log_success "  /etc/kubernetes cleaned"
    fi

    if [ "$cleanup_passed" = true ]; then
        log_success "Phase 4: Cleanup verification PASSED"
    else
        log_error "Phase 4: Cleanup verification FAILED"
    fi

    # Collect logs
    vm_ssh "cat /tmp/setup-k8s.log" > "$log_file" 2>/dev/null || true
    vm_ssh "cat /tmp/cleanup-k8s.log" >> "$log_file" 2>/dev/null || true

    # Write result JSON
    local final_status="failed"
    if [ "$test_passed" = true ] && [ "$cleanup_passed" = true ] && [ "$cleanup_exit_code" -eq 0 ]; then
        final_status="success"
    fi

    cat > "results/test-result.json" <<JSONEOF
{
  "status": "$final_status",
  "test_type": "generic-distro",
  "host_distro": "$HOST_DISTRO",
  "setup_test": {
    "exit_code": $setup_exit_code,
    "kubelet_active": $kubelet_active,
    "api_responsive": $api_responsive
  },
  "cleanup_test": {
    "exit_code": $cleanup_exit_code
  },
  "timestamp": "$(date -Iseconds)"
}
JSONEOF

    # Cleanup
    _generic_cleanup
    trap - EXIT INT TERM HUP

    if [ "$final_status" = "success" ]; then
        log_success "=== Generic Distro E2E Test: PASSED ==="
        return 0
    else
        log_error "=== Generic Distro E2E Test: FAILED ==="
        log_error "Logs saved to: $log_file"
        return 1
    fi
}

main() {
    parse_args "$@"
    run_test
}

main "$@"
