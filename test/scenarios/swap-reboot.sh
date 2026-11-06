#!/bin/bash
#
# Swap persistence E2E test via docker-vm-runner.
# Enables swap the ways distributions do at boot (an /etc/fstab entry and a
# systemd .swap unit), runs init, reboots the VM, and checks that swap stays
# off and kubelet comes back. Then checks that cleanup restores swap.
#
# Usage: ./test/scenarios/swap-reboot.sh [--distro <name>]
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

DOCKER_NETWORK="${DOCKER_NETWORK:-k8s-swap-net-$$}"
DOCKER_SUBNET="${DOCKER_SUBNET:-10.209.0.0/24}"
CP_DOCKER_IP="${CP_DOCKER_IP:-10.209.0.10}"

SSH_KEY_DIR=""
_init_test_defaults

show_help() {
    cat <<EOF
Swap Persistence E2E Test

Usage: $0 [OPTIONS]

Options:
  --distro <name>         Distribution to test (default: $DISTRO)
  --k8s-version <ver>     Kubernetes version (e.g., 1.37)
  --memory <MB>           VM memory (default: $VM_MEMORY)
  --cpus <count>          VM CPUs (default: $VM_CPUS)
  --disk-size <size>      VM disk size (default: $VM_DISK_SIZE)
  --help, -h              Show this help message
EOF
}

_root() { vm_ssh_root "$_CP_SSH_PORT" "$@"; }

# Reboot the VM and wait until root SSH works again.
_reboot_vm() {
    log_info "Rebooting VM..."
    _root "systemctl reboot" >/dev/null 2>&1 || true
    sleep 15
    local elapsed=0
    while [ "$elapsed" -lt "$SSH_READY_TIMEOUT" ]; do
        if _root "test -f /proc/swaps" >/dev/null 2>&1; then
            log_success "VM is back after reboot"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    log_error "VM did not come back after reboot"
    return 1
}

_check() {
    local desc="$1"; shift
    if "$@"; then
        log_success "CHECK: $desc"
    else
        log_error "CHECK: $desc"
        ALL_PASS=false
    fi
}

_swap_active() { [ -n "$(_root "swapon --noheadings --show=NAME" 2>/dev/null)" ]; }
_swap_inactive() { ! _swap_active; }
_kubelet_active() { [ "$(_root "systemctl is-active kubelet" 2>/dev/null)" = "active" ]; }
_api_ready() { _root "kubectl --kubeconfig=/etc/kubernetes/admin.conf get --raw=/readyz" >/dev/null 2>&1; }

# Wait up to <seconds> for a check to succeed.
_wait_for() {
    local seconds="$1"; shift
    local elapsed=0
    while [ "$elapsed" -lt "$seconds" ]; do
        if "$@"; then return 0; fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    return 1
}

run_swap_test() {
    _test_preamble "swap-reboot" "$DISTRO"
    local cp_container="k8s-swap-${DISTRO}-${_TEST_TS}"
    ALL_PASS=true

    trap '_cleanup_single_cp' EXIT INT TERM HUP
    create_single_cp_env "$cp_container" "swap" "k8s-swap-test" "k8s-swap-test" || return 1

    # /root, not /tmp: /tmp is cleared on reboot
    scp "${SSH_OPTS[@]}" -P "$_CP_SSH_PORT" "$HOST_BUNDLE" "root@localhost:/root/setup-k8s.sh" >/dev/null

    # --- Enable swap the way distributions do at boot ---
    log_info "Configuring boot-time swap (fstab entry and systemd swap unit)..."
    _root 'set -e
        fallocate -l 256M /swapfile-fstab && chmod 600 /swapfile-fstab && mkswap /swapfile-fstab >/dev/null
        echo "/swapfile-fstab none swap sw 0 0" >> /etc/fstab
        fallocate -l 256M /swapfile-unit && chmod 600 /swapfile-unit && mkswap /swapfile-unit >/dev/null
        printf "[Unit]\nDescription=Test swap\n[Swap]\nWhat=/swapfile-unit\n[Install]\nWantedBy=swap.target\n" > /etc/systemd/system/swapfile\\x2dunit.swap
        systemctl daemon-reload
        systemctl enable --now "swapfile\\x2dunit.swap"
        swapon -a' >> "$_TEST_LOG_FILE" 2>&1
    _check "swap is active before init" _swap_active

    # --- init ---
    local version_args=""
    [ -n "$K8S_VERSION" ] && version_args="--kubernetes-version $K8S_VERSION"
    log_info "Running init..."
    # shellcheck disable=SC2086 # version_args is empty or two words
    if _root "sh /root/setup-k8s.sh init $version_args" >> "$_TEST_LOG_FILE" 2>&1; then
        log_success "CHECK: init succeeded"
    else
        log_error "CHECK: init failed"
        ALL_PASS=false
    fi
    _check "swap is off after init" _swap_inactive

    # --- reboot ---
    _reboot_vm || ALL_PASS=false
    _check "swap stays off after reboot" _swap_inactive
    _check "kubelet is active after reboot" _wait_for 180 _kubelet_active
    _check "API server is ready after reboot" _wait_for 300 _api_ready
    _root "swapon --show; systemctl status kubelet --no-pager | head -20" >> "$_TEST_LOG_FILE" 2>&1 || true

    # --- cleanup restores swap ---
    log_info "Running cleanup..."
    _root "sh /root/setup-k8s.sh cleanup --force" >> "$_TEST_LOG_FILE" 2>&1 || ALL_PASS=false
    _reboot_vm || ALL_PASS=false
    _check "swap is restored after cleanup and reboot" _swap_active

    _test_result "SWAP-REBOOT" "$ALL_PASS" _cleanup_single_cp "$cp_container" "$_CP_SSH_PORT"
}

while [[ $# -gt 0 ]]; do
    if _parse_common_test_args "$@"; then shift "$SHIFT_COUNT"; continue; fi
    case $1 in
        --help|-h) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

if run_swap_test; then
    exit 0
else
    exit 1
fi
