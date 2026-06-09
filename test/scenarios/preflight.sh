#!/bin/bash
#
# Preflight Subcommand E2E Test via docker-vm-runner
# Usage: ./test/scenarios/preflight.sh [--distro <name>]
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

DOCKER_NETWORK="${DOCKER_NETWORK:-k8s-preflight-net-$$}"
DOCKER_SUBNET="${DOCKER_SUBNET:-10.208.0.0/24}"
CP_DOCKER_IP="${CP_DOCKER_IP:-10.208.0.10}"

SSH_KEY_DIR=""
_init_test_defaults

show_help() {
    cat <<EOF
Preflight Subcommand E2E Test

Usage: $0 [OPTIONS]

Options:
  --distro <name>         Distribution to test (default: $DISTRO)
  --memory <MB>           VM memory (default: $VM_MEMORY)
  --cpus <count>          VM CPUs (default: $VM_CPUS)
  --disk-size <size>      VM disk size (default: $VM_DISK_SIZE)
  --help, -h              Show this help message
EOF
}

run_preflight_case() {
    local name="$1" expected="$2"; shift 2
    local output exit_code=0

    log_info "Running preflight case: $name"
    output=$(vm_ssh_root "$_CP_SSH_PORT" "bash /tmp/setup-k8s.sh preflight $* 2>&1") || exit_code=$?
    printf '%s\n' "$output" >> "$_TEST_LOG_FILE"

    if [ "$expected" = "success" ] && [ "$exit_code" -eq 0 ]; then
        log_success "CHECK: $name exited 0"
        return 0
    fi
    if [ "$expected" = "failure" ] && [ "$exit_code" -ne 0 ]; then
        log_success "CHECK: $name failed as expected"
        return 0
    fi

    log_error "CHECK: $name unexpected exit code $exit_code (expected $expected)"
    printf '%s\n' "$output"
    return 1
}

run_preflight_test() {
    _test_preamble "preflight" "$DISTRO"
    local cp_container="k8s-preflight-${DISTRO}-${_TEST_TS}"
    local all_pass=true

    log_info "VM resources: memory=${VM_MEMORY}MB cpus=${VM_CPUS} disk=${VM_DISK_SIZE}"
    log_info "Docker network: $DOCKER_NETWORK ($DOCKER_SUBNET)"

    trap '_cleanup_single_cp' EXIT INT TERM HUP

    create_single_cp_env "$cp_container" "preflight" "k8s-preflight-test" "k8s-preflight-test"

    local bundle
    bundle=$(mktemp /tmp/setup-k8s-preflight-bundle.XXXXXX.sh)
    _generate_bundle "$SETUP_K8S_SCRIPT" "$bundle" "all"
    scp "${SSH_OPTS[@]}" -P "$_CP_SSH_PORT" "$bundle" "root@localhost:/tmp/setup-k8s.sh" >/dev/null
    rm -f "$bundle"
    vm_ssh_root "$_CP_SSH_PORT" "chmod +x /tmp/setup-k8s.sh"

    run_preflight_case "init-default" success --mode init --cri containerd --proxy-mode iptables || all_pass=false
    run_preflight_case "join-dry-run-crio-ipvs" success --dry-run --mode join --cri crio --proxy-mode ipvs || all_pass=false
    run_preflight_case "strict-dry-run-nftables" success --dry-run --mode init --proxy-mode nftables --preflight-strict || all_pass=false
    run_preflight_case "invalid-mode" failure --mode invalid || all_pass=false

    _test_result "PREFLIGHT" "$all_pass" _cleanup_single_cp "$cp_container" "$_CP_SSH_PORT"
}

while [[ $# -gt 0 ]]; do
    if _parse_common_test_args "$@"; then shift "$SHIFT_COUNT"; continue; fi
    case $1 in
        --help|-h) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

if run_preflight_test; then
    exit 0
else
    exit 1
fi
