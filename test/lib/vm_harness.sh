#!/bin/bash
#
# Shared VM test harness for docker-vm-runner based tests.
# Provides: logging, SSH key management, port allocation, watchdog, bundle generation.
#
# Usage: source "$SCRIPT_DIR/lib/vm_harness.sh"
#

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }

# Guard for options requiring a value argument (prevents unbound variable under set -u)
_require_arg() {
    if [ "$1" -lt 2 ]; then
        log_error "$2 requires a value"
        exit 1
    fi
}

# Generate a temporary SSH keypair for this test session
setup_ssh_key() {
    SSH_KEY_DIR=$(mktemp -d)
    ssh-keygen -t ed25519 -f "$SSH_KEY_DIR/id_test" -N "" -q
    SSH_OPTS+=(-i "$SSH_KEY_DIR/id_test")
}

cleanup_ssh_key() {
    if [ -n "$SSH_KEY_DIR" ] && [ -d "$SSH_KEY_DIR" ]; then
        rm -rf "$SSH_KEY_DIR"
        SSH_KEY_DIR=""
    fi
    # Reset SSH_OPTS to base (remove stale -i options from previous runs)
    SSH_OPTS=("${SSH_BASE_OPTS[@]}")
    _VM_ESCALATE_CMD=""
}

# Find a free port for SSH forwarding (with retry to mitigate race conditions)
find_free_port() {
    local port
    for _ in 1 2 3 4 5; do
        port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()')
        # Verify port is still free
        if ! ss -tln | grep -q ":${port}\b"; then
            echo "$port"
            return 0
        fi
        sleep 0.1
    done
    log_error "Failed to find a free port after 5 attempts"
    return 1
}

# Start a watchdog process that stops the container when the parent exits.
# Returns the watchdog PID via stdout.
# Usage: _WATCHDOG_PID=$(_start_vm_container_watchdog "$$" "$container_name")
_start_vm_container_watchdog() {
    local parent_pid=$1 container_name=$2
    setsid bash <<WATCHDOG_EOF </dev/null >/dev/null 2>&1 &
while kill -0 "$parent_pid" >/dev/null 2>&1; do sleep 2; done
docker stop "$container_name" >/dev/null 2>&1 || true
WATCHDOG_EOF
    echo "$!"
}

# Stop a single VM container and its watchdog.
# Usage: _cleanup_vm_container "$watchdog_pid" "$container_name"
#   Both arguments are values (PID and container name).
_cleanup_vm_container() {
    local _wpid="$1" _cname="$2"
    if [ -n "$_wpid" ]; then
        kill "$_wpid" >/dev/null 2>&1 || true
    fi
    if [ -n "$_cname" ]; then
        log_info "Stopping container $_cname..."
        docker stop "$_cname" >/dev/null 2>&1 || true
    fi
}

# Single CP cleanup (backup, renew tests)
_cleanup_single_cp() {
    _cleanup_vm_container "$_CP_WATCHDOG_PID" "$_CP_CONTAINER_NAME"
    _CP_WATCHDOG_PID=""
    _CP_CONTAINER_NAME=""
    cleanup_docker_network
    cleanup_ssh_key
}

# CP + Worker cleanup (deploy, upgrade tests)
_cleanup_cp_worker() {
    _cleanup_vm_container "$_CP_WATCHDOG_PID" "$_CP_CONTAINER_NAME"
    _CP_WATCHDOG_PID=""
    _CP_CONTAINER_NAME=""
    _cleanup_vm_container "$_WORKER_WATCHDOG_PID" "$_WORKER_CONTAINER_NAME"
    _WORKER_WATCHDOG_PID=""
    _WORKER_CONTAINER_NAME=""
    cleanup_docker_network
    cleanup_ssh_key
}

# Stop orphaned containers by label (shared across test runners)
# Usage: cleanup_orphaned_containers <label>
cleanup_orphaned_containers() {
    local label=$1
    docker ps -q --filter "label=managed-by=$label" 2>/dev/null | while read -r cid; do
        log_warn "Stopping orphaned container: $(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | tr -d '/')"
        docker stop "$cid" >/dev/null 2>&1 || true
    done
}

# Generate a self-contained bundle script for bundled test execution.
# Usage: _generate_bundle <entry_script> <bundle_path> [include_mode]
#   entry_script:  path to the entry script (setup-k8s.sh)
#   bundle_path:   output file path
#   include_mode:  "true"/"all" to include all distro modules, "cleanup" for cleanup-only
_generate_bundle() {
    local entry_script="$1" bundle_path="$2" include_mode="${3:-all}"
    local project_root
    project_root="$(cd "$(dirname "$entry_script")" && pwd)"
    local _had_k8s_version=0 _saved_k8s_version=""
    if [ "${K8S_VERSION+x}" ]; then
        _had_k8s_version=1
        _saved_k8s_version="$K8S_VERSION"
    fi

    # Source bootstrap (provides _COMMON_MODULES), variables (provides
    # BUNDLE_COMMON_MODULES), and bundle (provides _generate_bundle_core)
    if ! type -t _generate_bundle_core &>/dev/null; then
        # Save caller's EXIT trap (bootstrap.sh unconditionally sets its own)
        local _saved_exit_trap
        _saved_exit_trap=$(trap -p EXIT)
        source "${project_root}/lib/bootstrap.sh"
        source "${project_root}/lib/variables.sh"
        source "${project_root}/lib/bundle.sh"
        # Restore caller's EXIT trap (or clear bootstrap's if caller had none)
        if [ -n "$_saved_exit_trap" ]; then
            eval "$_saved_exit_trap"
        else
            trap - EXIT
        fi
    fi
    if [ "$_had_k8s_version" -eq 1 ]; then
        K8S_VERSION="$_saved_k8s_version"
    else
        unset K8S_VERSION
    fi

    _generate_bundle_core "$bundle_path" "$entry_script" "$include_mode" "$project_root"
}

# Resolve latest stable Kubernetes minor version from dl.k8s.io.
# Sets K8S_VERSION if not already set.
# Usage: resolve_k8s_version
resolve_k8s_version() {
    if [ -n "$K8S_VERSION" ]; then return 0; fi
    log_info "Resolving latest stable Kubernetes version..."
    local stable_txt
    if ! stable_txt=$(curl -fsSL --retry 3 --retry-delay 2 https://dl.k8s.io/release/stable.txt); then
        log_error "Failed to fetch stable Kubernetes version from dl.k8s.io"
        return 1
    fi
    if echo "$stable_txt" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+'; then
        K8S_VERSION=$(echo "$stable_txt" | sed -E 's/^v([0-9]+\.[0-9]+)\..*/\1/')
        log_success "Detected: $K8S_VERSION"
    else
        log_error "Unexpected response from dl.k8s.io: $stable_txt"
        return 1
    fi
}

# Poll a VM for command completion via exit code file.
# Usage: poll_vm_command <ssh_func> <container_name> <exit_code_file> <log_file> <timeout> [<interval>]
#   ssh_func:        function to call for SSH commands (receives command as args)
#   container_name:  docker container name (for health checks)
#   exit_code_file:  remote path to the exit code file (e.g., /tmp/setup-exit-code)
#   log_file:        remote path to the log file for progress display (e.g., /tmp/setup-k8s.log)
#   timeout:         max seconds to wait
#   interval:        poll interval in seconds (default: 10)
# Returns: 0 on completion, 1 on timeout/container exit.
# Sets POLL_EXIT_CODE to the contents of the exit code file.
POLL_EXIT_CODE=""
poll_vm_command() {
    local ssh_func=$1 container_name=$2 exit_code_file=$3 log_file=$4 timeout=$5 interval=${6:-10}
    POLL_EXIT_CODE=""

    local start_time elapsed
    start_time=$(date +%s)
    while true; do
        elapsed=$(( $(date +%s) - start_time ))
        if [ $elapsed -gt "$timeout" ]; then
            log_error "Command timeout after ${timeout}s"
            return 1
        fi
        if ! docker inspect "$container_name" >/dev/null 2>&1; then
            log_error "Container exited unexpectedly"
            return 1
        fi
        if $ssh_func "test -f $exit_code_file" >/dev/null 2>&1; then
            break
        fi
        local progress_line
        progress_line=$($ssh_func "tail -1 $log_file" 2>/dev/null || true)
        [ -n "$progress_line" ] && log_info "[${elapsed}s] $progress_line"
        sleep "$interval"
    done

    local _raw_exit
    if ! _raw_exit=$($ssh_func "cat $exit_code_file" 2>/dev/null); then
        log_error "Failed to read exit code file from remote"
        return 1
    fi
    # shellcheck disable=SC2034 # read by callers after poll_vm_command returns
    POLL_EXIT_CODE=$(echo "$_raw_exit" | tr -d '[:space:]')
    if ! [[ "$POLL_EXIT_CODE" =~ ^[0-9]+$ ]]; then
        log_error "Invalid exit code from remote: '$POLL_EXIT_CODE'"
        return 1
    fi
}

# Wait for the docker-vm-runner guest to become ready.
# Usage: wait_for_cloud_init <container_name> <timeout> <label>
wait_for_cloud_init() {
    local container_name=$1 timeout=$2 label=$3

    log_info "[$label] Waiting for guest readiness (timeout: ${timeout}s)..."
    local elapsed=0
    while [ $elapsed -lt "$timeout" ]; do
        if ! docker inspect "$container_name" >/dev/null 2>&1; then
            log_error "[$label] Container exited before guest became ready"
            return 1
        fi

        local health
        health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_name" 2>/dev/null || true)
        case "$health" in
            healthy|none) break ;;
            unhealthy) ;;
        esac

        sleep 5
        elapsed=$((elapsed + 5))
        (( elapsed % 30 == 0 )) && log_info "[$label] Still waiting... (${elapsed}s)"
    done
    if [ $elapsed -ge "$timeout" ]; then
        log_error "[$label] Guest readiness timeout after ${timeout}s"
        return 1
    fi
    log_success "[$label] Guest is ready"
}

# Wait for SSH to become available.
# Usage: wait_for_ssh <port> <user> <timeout> <label>
wait_for_ssh() {
    local port=$1 user=$2 timeout=$3 label=$4

    log_info "[$label] Waiting for SSH..."
    local elapsed=0
    while [ $elapsed -lt "$timeout" ]; do
        if ssh "${SSH_OPTS[@]}" -p "$port" "${user}@localhost" "echo ready" >/dev/null 2>&1; then
            break
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
    if [ $elapsed -ge "$timeout" ]; then
        log_error "[$label] SSH not available after ${timeout}s"
        return 1
    fi
    log_success "[$label] SSH is ready"
}

wait_for_guest_bootstrap() {
    local port=$1 user=$2 timeout=$3 label=$4

    log_info "[$label] Waiting for guest bootstrap tasks..."
    local remote_script
    remote_script=$(cat <<REMOTE_SCRIPT
set -eu
if command -v cloud-init >/dev/null 2>&1; then
    cloud-init status --wait >/dev/null 2>&1 || true
fi
if command -v apt-get >/dev/null 2>&1; then
    end=\$(( \$(date +%s) + $timeout ))
    while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; do
        if [ "\$(date +%s)" -ge "\$end" ]; then
            exit 124
        fi
        sleep 3
    done
fi
REMOTE_SCRIPT
)
    local quoted_script
    quoted_script=$(printf '%q' "$remote_script")
    if ssh "${SSH_OPTS[@]}" -p "$port" "$user@localhost" \
        "if command -v sudo >/dev/null 2>&1; then sudo sh -c $quoted_script; elif command -v doas >/dev/null 2>&1; then doas sh -c $quoted_script; else sh -c $quoted_script; fi" >/dev/null 2>&1; then
        log_success "[$label] Guest bootstrap tasks are complete"
        return 0
    fi
    log_error "[$label] Guest bootstrap tasks did not complete within ${timeout}s"
    return 1
}

# Detect privilege escalation command (sudo or doas) on the remote VM.
# Caches the result in _VM_ESCALATE_CMD for subsequent calls.
_VM_ESCALATE_CMD=""
_detect_escalate_cmd() {
    if [ -n "$_VM_ESCALATE_CMD" ]; then return; fi
    if ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "$LOGIN_USER@localhost" "command -v sudo" >/dev/null 2>&1; then
        _VM_ESCALATE_CMD="sudo"
    elif ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "$LOGIN_USER@localhost" "command -v doas" >/dev/null 2>&1; then
        _VM_ESCALATE_CMD="doas"
    else
        log_warn "Neither sudo nor doas found on VM — running commands without escalation"
        _VM_ESCALATE_CMD=""
    fi
}

# SSH helper: run command on VM as root (requires SSH_OPTS, SSH_PORT, LOGIN_USER)
vm_ssh() {
    _detect_escalate_cmd
    ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "$LOGIN_USER@localhost" $_VM_ESCALATE_CMD "$@"
}

# SCP helper: copy file to VM (requires SSH_OPTS, SSH_PORT, LOGIN_USER)
vm_scp() {
    local local_path=$1 remote_path=$2
    scp "${SSH_OPTS[@]}" -P "$SSH_PORT" "$local_path" "${LOGIN_USER}@localhost:${remote_path}"
}

# --- Shared Docker network and VM lifecycle helpers ---

# Create Docker network for VM tests (requires DOCKER_NETWORK, DOCKER_SUBNET)
setup_docker_network() {
    log_info "Creating Docker network: $DOCKER_NETWORK ($DOCKER_SUBNET)"
    docker network rm "$DOCKER_NETWORK" >/dev/null 2>&1 || true
    local create_err
    if ! create_err=$(docker network create --subnet "$DOCKER_SUBNET" "$DOCKER_NETWORK" 2>&1 >/dev/null); then
        log_error "Failed to create Docker network $DOCKER_NETWORK ($DOCKER_SUBNET): $create_err"
        return 1
    fi
    log_success "Docker network created"
}

# Remove Docker network if it exists
cleanup_docker_network() {
    if docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1; then
        log_info "Removing Docker network: $DOCKER_NETWORK"
        docker network rm "$DOCKER_NETWORK" >/dev/null 2>&1 || true
    fi
}

# Start a VM container with static IP on the Docker network
# Usage: start_vm <container_name> <static_ip> <host_ssh_port> <data_subdir> [label]
start_vm() {
    local container_name=$1 static_ip=$2 host_ssh_port=$3 data_subdir=$4
    local label="${5:-managed-by=k8s-test}"

    if type -t test_validate_runner_distro >/dev/null; then
        test_validate_runner_distro "$DISTRO" || return 1
    fi

    local vm_data_dir="$VM_DATA_DIR/$data_subdir"
    mkdir -p "$vm_data_dir"

    log_info "Starting VM: $container_name (IP: $static_ip, SSH port: $host_ssh_port)"
    if ! docker run -d --rm \
        --name "$container_name" \
        --label "$label" \
        --network "$DOCKER_NETWORK" --ip "$static_ip" \
        --device /dev/kvm:/dev/kvm \
        -v "$vm_data_dir:/data" \
        -p "${host_ssh_port}:2222" \
        -e "DISTRO=$DISTRO" \
        -e "GUEST_NAME=$container_name" \
        -e "SSH_PUBKEY=$(cat "$SSH_KEY_DIR/id_test.pub")" \
        -e "PORT_FWD=6443:6443,10250:10250" \
        -e "NO_CONSOLE=1" \
        -e "MEMORY=$VM_MEMORY" \
        -e "CPUS=$VM_CPUS" \
        -e "DISK_SIZE=$VM_DISK_SIZE" \
        "$DOCKER_VM_RUNNER_IMAGE" >/dev/null; then
        log_error "Failed to start container $container_name"
        return 1
    fi
    log_success "Container $container_name started"
}

# Wait for cloud-init + SSH to become ready on a VM
# Usage: wait_for_vm_ready <container_name> <host_ssh_port> <label>
wait_for_vm_ready() {
    local container_name=$1 host_ssh_port=$2 label=$3
    wait_for_cloud_init "$container_name" "$SSH_READY_TIMEOUT" "$label" || return 1
    wait_for_ssh "$host_ssh_port" "$LOGIN_USER" "$SSH_READY_TIMEOUT" "$label" || return 1
    wait_for_guest_bootstrap "$host_ssh_port" "$LOGIN_USER" "$SSH_READY_TIMEOUT" "$label" || return 1
}

# Setup root SSH access on a VM (copy user's authorized_keys to root)
# Usage: setup_root_ssh <host_ssh_port> <label>
setup_root_ssh() {
    local host_ssh_port=$1 label=$2

    log_info "[$label] Setting up root SSH access..."
    ssh "${SSH_OPTS[@]}" -p "$host_ssh_port" "$LOGIN_USER@localhost" \
        "sudo mkdir -p /root/.ssh && sudo cp ~/.ssh/authorized_keys /root/.ssh/ && sudo chmod 700 /root/.ssh && sudo chmod 600 /root/.ssh/authorized_keys" >/dev/null 2>&1

    if ssh "${SSH_OPTS[@]}" -p "$host_ssh_port" "root@localhost" "echo ok" >/dev/null 2>&1; then
        log_success "[$label] Root SSH access ready"
    else
        log_error "[$label] Root SSH access failed"
        return 1
    fi
}

# SSH to a VM as root
# Usage: vm_ssh_root <port> <command...>
vm_ssh_root() {
    local port=$1; shift
    ssh "${SSH_OPTS[@]}" -p "$port" "root@localhost" "$@"
}

# --- Common test defaults ---
: "${DOCKER_VM_RUNNER_IMAGE:=ghcr.io/munenick/docker-vm-runner:latest}"
: "${VM_MEMORY:=4096}"
: "${VM_CPUS:=2}"
: "${VM_DISK_SIZE:=40G}"
: "${TIMEOUT_TOTAL:=1200}"
: "${SSH_READY_TIMEOUT:=300}"

# --- Scenario environment helpers ---
# These set up complete VM environments for common test scenarios.
# Callers must define: DOCKER_NETWORK, DOCKER_SUBNET, CP_DOCKER_IP,
#   VM_DATA_DIR, DISTRO, SSH_KEY_DIR, SSH_BASE_OPTS, SSH_OPTS, LOGIN_USER
# After calling, callers have: _CP_CONTAINER_NAME, _CP_WATCHDOG_PID, _CP_SSH_PORT
#   (and _WORKER_* equivalents for create_cp_worker_env)

# Create a single control-plane VM environment.
# Usage: create_single_cp_env <container_name> <data_subdir> <managed_by_label> <orphan_label>
create_single_cp_env() {
    local container_name=$1 data_subdir=$2 managed_by_label=$3 orphan_label=$4

    cleanup_orphaned_containers "$orphan_label" || true
    setup_docker_network || return 1
    setup_ssh_key || return 1

    _CP_SSH_PORT=$(find_free_port) || return 1

    start_vm "$container_name" "$CP_DOCKER_IP" "$_CP_SSH_PORT" "$data_subdir" "managed-by=$managed_by_label" || return 1
    _CP_CONTAINER_NAME="$container_name"
    _CP_WATCHDOG_PID=$(_start_vm_container_watchdog "$$" "$container_name")

    wait_for_vm_ready "$container_name" "$_CP_SSH_PORT" "CP" || return 1
    setup_root_ssh "$_CP_SSH_PORT" "CP" || return 1
    return 0
}

# Create a control-plane + worker VM environment.
# Usage: create_cp_worker_env <cp_name> <worker_name> <cp_data> <worker_data> <managed_by> <orphan_label>
# Requires: WORKER_DOCKER_IP defined by caller
create_cp_worker_env() {
    local cp_name=$1 worker_name=$2 cp_data=$3 worker_data=$4 managed_by=$5 orphan_label=$6

    cleanup_orphaned_containers "$orphan_label" || true
    setup_docker_network || return 1
    setup_ssh_key || return 1

    _CP_SSH_PORT=$(find_free_port) || return 1
    _WORKER_SSH_PORT=$(find_free_port) || return 1

    start_vm "$cp_name" "$CP_DOCKER_IP" "$_CP_SSH_PORT" "$cp_data" "managed-by=$managed_by" || return 1
    _CP_CONTAINER_NAME="$cp_name"
    _CP_WATCHDOG_PID=$(_start_vm_container_watchdog "$$" "$cp_name")

    start_vm "$worker_name" "$WORKER_DOCKER_IP" "$_WORKER_SSH_PORT" "$worker_data" "managed-by=$managed_by" || return 1
    _WORKER_CONTAINER_NAME="$worker_name"
    _WORKER_WATCHDOG_PID=$(_start_vm_container_watchdog "$$" "$worker_name")

    wait_for_vm_ready "$cp_name" "$_CP_SSH_PORT" "CP" || return 1
    wait_for_vm_ready "$worker_name" "$_WORKER_SSH_PORT" "Worker" || return 1

    setup_root_ssh "$_CP_SSH_PORT" "CP" || return 1
    setup_root_ssh "$_WORKER_SSH_PORT" "Worker" || return 1
    return 0
}

# Common arg parser for --distro, --k8s-version, --memory, --cpus, --disk-size
# Returns 0 and shifts args if handled; returns 1 for unknown args (caller handles).
# Usage: _parse_common_test_args "$@" && shift $SHIFT_COUNT
# shellcheck disable=SC2034 # SHIFT_COUNT used by caller via: shift $SHIFT_COUNT
_parse_common_test_args() {
    SHIFT_COUNT=0
    case "${1:-}" in
        --distro) _require_arg $# "$1"; DISTRO="$2"; SHIFT_COUNT=2 ;;
        --k8s-version) _require_arg $# "$1"; K8S_VERSION="$2"; SHIFT_COUNT=2 ;;
        --memory) _require_arg $# "$1"; VM_MEMORY="$2"; SHIFT_COUNT=2 ;;
        --cpus) _require_arg $# "$1"; VM_CPUS="$2"; SHIFT_COUNT=2 ;;
        --disk-size) _require_arg $# "$1"; VM_DISK_SIZE="$2"; SHIFT_COUNT=2 ;;
        *) return 1 ;;
    esac
    return 0
}

# --- Common E2E test boilerplate helpers ---

# Initialize common test defaults (called at file top level of each test).
_init_test_defaults() {
    SSH_BASE_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
                   -o LogLevel=ERROR -o ConnectTimeout=5)
    SSH_OPTS=("${SSH_BASE_OPTS[@]}")
    LOGIN_USER="user"
    _CP_CONTAINER_NAME=""
    _CP_WATCHDOG_PID=""
    _CP_SSH_PORT=""
}

# Generate test preamble: timestamp, log file, banner.
# Usage: _test_preamble <test_name> <distro>
# Sets: _TEST_TS, _TEST_LOG_FILE
_test_preamble() {
    local test_name="$1" distro="$2"
    _TEST_TS=$(date +%s)
    _TEST_LOG_FILE="results/logs/${test_name}-${distro}-$(date +%Y%m%d-%H%M%S).log"
    log_info "=== ${test_name} E2E Test ==="
    log_info "Distro: $distro"
    mkdir -p results/logs "$VM_DATA_DIR"
}

# Evaluate test result and handle cleanup/diagnostics.
# Usage: _test_result <test_name> <all_pass> <cleanup_fn> [diag_container] [diag_port]
_test_result() {
    local test_name="$1" all_pass="$2" cleanup_fn="$3"
    local diag_container="${4:-}" diag_port="${5:-}"
    if [ "$all_pass" = true ]; then
        log_success "=== ${test_name} TEST PASSED ==="
        "$cleanup_fn"; trap - EXIT INT TERM HUP
        return 0
    else
        log_error "=== ${test_name} TEST FAILED ==="
        if [ -n "$diag_container" ] && [ -n "$diag_port" ]; then
            collect_vm_diagnostics "$diag_container" "$diag_port" || true
        fi
        "$cleanup_fn"; trap - EXIT INT TERM HUP
        return 1
    fi
}

# --- Common E2E test helpers ---

# Timeout-guarded command execution. Sets the named variable to the exit code.
# Usage: run_with_timeout <var_name> <log_file> <command...>
run_with_timeout() {
    local _var_name=$1 _log_file=$2; shift 2
    local _exit_code=0
    if timeout "$TIMEOUT_TOTAL" "$@" 2>&1 | tee -a "$_log_file"; then _exit_code=0
    else _exit_code=$?; [ "$_exit_code" -eq 124 ] && log_error "Timed out after ${TIMEOUT_TOTAL}s"; fi
    eval "${_var_name}=${_exit_code}"
}

# Wait for the Kubernetes API server to become ready via SSH.
# Usage: wait_for_api_ready <port> [max_attempts] [interval]
wait_for_api_ready() {
    local port=$1 max=${2:-20} interval=${3:-5} i=0
    while [ $i -lt "$max" ]; do
        vm_ssh_root "$port" "kubectl get nodes --kubeconfig=/etc/kubernetes/admin.conf" >/dev/null 2>&1 && return 0
        sleep "$interval"; i=$((i + 1))
    done; return 1
}

# Record a check result. Sets all_pass=false on failure.
# Usage: check_pass <num> <description> <result_bool>
check_pass() {
    local num=$1 desc="$2" result="$3"
    if [ "$result" = "true" ]; then log_success "CHECK ${num}: ${desc}"
    else log_error "CHECK ${num}: ${desc}"; all_pass=false; fi
}

# Collect diagnostics from VMs for debugging test failures.
# Usage: collect_vm_diagnostics <container_name> <port> [port2] ...
collect_vm_diagnostics() {
    local cname=$1; shift
    log_info "=== DIAGNOSTICS ==="
    log_info "$cname logs (last 20 lines):"; docker logs "$cname" 2>&1 | tail -20 || true
    for port in "$@"; do
        log_info "Ports ($port):"; vm_ssh_root "$port" "ss -tlnp | grep -E '6443|10250'" 2>/dev/null || true
    done
    log_info "=== END DIAGNOSTICS ==="
}
