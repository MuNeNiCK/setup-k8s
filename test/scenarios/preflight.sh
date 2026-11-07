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

# Usage: run_preflight_case <name> <success|failure> <output_regex> [preflight args...]
# The exit status must match and the output must match <output_regex>.
run_preflight_case() {
    local name="$1" expected="$2" pattern="$3"; shift 3
    local output exit_code=0 ok=true

    log_info "Running preflight case: $name"
    output=$(vm_ssh_root "$_CP_SSH_PORT" "sh /tmp/setup-k8s.sh preflight $* 2>&1") || exit_code=$?
    printf '%s\n' "$output" >> "$_TEST_LOG_FILE"

    if [ "$expected" = "success" ] && [ "$exit_code" -ne 0 ]; then ok=false; fi
    if [ "$expected" = "failure" ] && [ "$exit_code" -eq 0 ]; then ok=false; fi
    if ! printf '%s\n' "$output" | grep -q -E "$pattern"; then ok=false; fi

    if [ "$ok" = true ]; then
        log_success "CHECK: $name (exit $exit_code, output matches /$pattern/)"
        return 0
    fi
    log_error "CHECK: $name: exit $exit_code (expected $expected), output must match /$pattern/"
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
    _generate_bundle "$SETUP_K8S_SCRIPT" "$bundle"
    scp "${SSH_OPTS[@]}" -P "$_CP_SSH_PORT" "$bundle" "root@localhost:/tmp/setup-k8s.sh" >/dev/null
    rm -f "$bundle"
    vm_ssh_root "$_CP_SSH_PORT" "chmod +x /tmp/setup-k8s.sh"

    # A fresh node passes, and auto resolves to nftables on a current kernel
    run_preflight_case "init-default" success 'Failed: 0' --mode init || all_pass=false
    run_preflight_case "proxy-mode-auto" success 'auto resolves to nftables' --mode init --proxy-mode auto || all_pass=false
    # A dry run lists the checks and runs none
    run_preflight_case "join-dry-run" success 'Dry-run|dry-run' --dry-run --mode join --cri crio --proxy-mode ipvs || all_pass=false

    # The API server port in use fails init checks (not join)
    vm_ssh_root "$_CP_SSH_PORT" "nohup python3 -m http.server 6443 >/dev/null 2>&1 & sleep 2" || true
    run_preflight_case "port-6443-in-use" failure '6443' --mode init || all_pass=false
    vm_ssh_root "$_CP_SSH_PORT" "pkill -f 'http.server 6443'" || true

    # Swap is a warning; --preflight-strict turns warnings into a failure
    vm_ssh_root "$_CP_SSH_PORT" "fallocate -l 128M /swap-preflight && chmod 600 /swap-preflight && mkswap /swap-preflight >/dev/null && swapon /swap-preflight" || true
    run_preflight_case "swap-warning" success '\[WARN\].*[Ss]wap' --mode init || all_pass=false
    run_preflight_case "swap-strict" failure '[Ss]wap' --mode init --preflight-strict || all_pass=false
    vm_ssh_root "$_CP_SSH_PORT" "swapoff /swap-preflight; rm -f /swap-preflight" || true

    run_preflight_case "invalid-mode" failure 'mode' --mode invalid || all_pass=false

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
