#!/bin/bash
#
# K8s Multi-Distribution Test Runner
# Usage: ./run-e2e-tests.sh <distro-name>
#

set -euo pipefail

# Constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test/lib/vm_harness.sh
source "$SCRIPT_DIR/lib/vm_harness.sh"

SETUP_K8S_SCRIPT="$SCRIPT_DIR/../setup-k8s.sh"
# cleanup is now integrated into setup-k8s.sh as the 'cleanup' subcommand
DOCKER_VM_RUNNER_IMAGE="${DOCKER_VM_RUNNER_IMAGE:-ghcr.io/munenick/docker-vm-runner:latest}"
GITHUB_BASE_URL="${GITHUB_BASE_URL:-https://raw.githubusercontent.com/MuNeNiCK/setup-k8s/main}"
VM_DATA_DIR="${VM_DATA_DIR:-$SCRIPT_DIR/data}"

SUPPORTED_DISTROS=(
    ubuntu-2404
    ubuntu-2204
    debian-13
    debian-12
    debian-11
    centos-stream-10
    centos-stream-9
    fedora-43
    opensuse-tumbleweed
    opensuse-leap-160
    rocky-linux-10
    rocky-linux-9
    rocky-linux-8
    almalinux-10
    almalinux-9
    almalinux-8
    oracle-linux-9
    archlinux
    alpine-3
)

# VM resource defaults
VM_MEMORY="${VM_MEMORY:-8192}"
VM_CPUS="${VM_CPUS:-4}"
VM_DISK_SIZE="${VM_DISK_SIZE:-40G}"

# K8s version (can be overridden by command line option)
K8S_VERSION=""
# Extra args to pass to setup-k8s.sh
SETUP_EXTRA_ARGS=()
# Test mode (offline or online)
TEST_MODE="offline"
# Login user (fixed: docker-vm-runner vendor cloud-config creates 'user')
LOGIN_USER="user"

# Timeout settings (seconds)
TIMEOUT_TOTAL=1200    # 20 minutes
SSH_READY_TIMEOUT=300 # 5 minutes for SSH to become available

# SSH settings
SSH_KEY_DIR=""
SSH_PORT=""
SSH_BASE_OPTS=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
# shellcheck disable=SC2034 # SSH_OPTS is used by vm_ssh/vm_scp in vm_harness.sh
SSH_OPTS=("${SSH_BASE_OPTS[@]}")

# Global cleanup state (must be module-level for EXIT trap)
_VM_CONTAINER_NAME=""
_WATCHDOG_PID=""
_CLOUD_INIT_USER_DATA=""

_e2e_cleanup_vm_container() {
    _cleanup_vm_container "$_WATCHDOG_PID" "$_VM_CONTAINER_NAME"
    _WATCHDOG_PID=""
    _VM_CONTAINER_NAME=""
    rm -f "$_CLOUD_INIT_USER_DATA"
    _CLOUD_INIT_USER_DATA=""
}

# Help message
show_help() {
    cat <<EOF
K8s Multi-Distribution Test Runner

Usage: $0 [OPTIONS] <distro-name>

Options:
  --all, -a                 Test all distributions sequentially
  --k8s-version <version>   Kubernetes version to test (e.g., 1.32, 1.31, 1.30)
  --setup-args ARGS         Extra args for setup-k8s.sh (use quotes)
  --online                  Run test using curl | bash from GitHub (requires push)
  --offline                 Run test in bundled mode with local code (default)
  --memory <MB>             VM memory in MB (default: $VM_MEMORY)
  --cpus <count>            VM CPU count (default: $VM_CPUS)
  --disk-size <size>        VM disk size (default: $VM_DISK_SIZE)
  --                        Treat the rest as setup-args
  --help, -h                Show this help message

Supported distributions:
EOF
    for distro in "${SUPPORTED_DISTROS[@]}"; do
        echo "  - $distro"
    done
    echo
    echo "Examples:"
    echo "  $0 ubuntu-2404                        # Test single distribution offline (bundled)"
    echo "  $0 --online ubuntu-2404               # Test single distribution via curl | bash from GitHub"
    echo "  $0 --k8s-version 1.31 ubuntu-2404     # Test with specific k8s version"
    echo "  $0 --all                              # Test all distributions offline"
    echo "  $0 --all --online                     # Test all distributions via curl | bash"
    echo "  $0 --all --k8s-version 1.30           # Test all distributions with k8s v1.30"
    echo "  $0 --memory 16384 --cpus 8 ubuntu-2404  # Test with custom VM resources"
    echo "  $0 archlinux"
    echo "  $0 --k8s-version 1.32 rocky-linux-8"
    echo
    echo "Test Modes:"
    echo "  Online:  Runs curl | bash from GitHub inside VM (tests production flow; requires push)"
    echo "  Offline: Uses pre-bundled script with local code (default; no push required)"
}

# Prepare data directory for docker-vm-runner (mounted as /data in container)
prepare_runner_directories() {
    mkdir -p "$VM_DATA_DIR"
}

# Load configuration function
load_config() {
    local distro=$1
    local found=false
    for d in "${SUPPORTED_DISTROS[@]}"; do
        if [ "$d" = "$distro" ]; then found=true; break; fi
    done
    if [ "$found" = false ]; then
        log_error "Unknown distribution: $distro"
        echo "Available distributions:"
        printf '  %s\n' "${SUPPORTED_DISTROS[@]}"
        return 1
    fi
    log_info "Configuration loaded:"
    log_info "  Distribution: $distro"
    log_info "  Login user: $LOGIN_USER"
    return 0
}

# Global path for generated bundle (set by generate_bundled_scripts)
_SETUP_BUNDLE=""

# Generate bundled script for offline mode
generate_bundled_scripts() {
    _SETUP_BUNDLE=$(mktemp /tmp/setup-k8s-bundle.XXXXXX.sh)

    log_info "Generating bundled script..."
    _generate_bundle "$SETUP_K8S_SCRIPT" "$_SETUP_BUNDLE" "all"
    log_info "Bundled script generated successfully"
}

# Execute and monitor VM via SSH
run_vm_container() {
    local distro=$1
    local k8s_version_flag=$2
    local k8s_version_val=$3
    local setup_extra_args_str=$4
    local container_name
    container_name="k8s-vm-${distro}-$(date +%s)"
    local log_file
    log_file="results/logs/${distro}-$(date +%Y%m%d-%H%M%S).log"

    log_info "Starting docker-vm-runner for: $distro"
    log_info "VM resources: memory=${VM_MEMORY}MB cpus=${VM_CPUS} disk=${VM_DISK_SIZE}"
    mkdir -p results/logs
    rm -f results/test-result.json

    # Clean up any leftover container from a previous failed test (safety net for --all mode)
    _e2e_cleanup_vm_container

    # Stop orphaned containers from previous interrupted runs (label-based)
    cleanup_orphaned_containers "k8s-test-runner"

    # Register container for cleanup (module-level for EXIT trap)
    _VM_CONTAINER_NAME=""
    trap '_e2e_cleanup_vm_container; cleanup_ssh_key' EXIT INT TERM HUP

    # Generate SSH keypair for this test
    setup_ssh_key
    SSH_PORT=$(find_free_port)

    # Start container in detached mode
    log_info "Starting container: $container_name (SSH port: $SSH_PORT)"

    # Build docker run args
    local -a _docker_run_args=(
        docker run -d --rm
        --name "$container_name"
        --label "managed-by=k8s-test-runner"
        --device /dev/kvm:/dev/kvm
        -v "$VM_DATA_DIR:/data"
        -p "${SSH_PORT}:2222"
        -e "DISTRO=$distro"
        -e "GUEST_NAME=$container_name"
        -e "SSH_PUBKEY=$(cat "$SSH_KEY_DIR/id_test.pub")"
        -e "NO_CONSOLE=1"
        -e "MEMORY=$VM_MEMORY"
        -e "CPUS=$VM_CPUS"
        -e "DISK_SIZE=$VM_DISK_SIZE"
    )

    # Alpine: cloud image has no bash/sudo/openssh pre-installed
    case "$distro" in
        alpine-*)
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
            _docker_run_args+=(
                -v "$_CLOUD_INIT_USER_DATA:/cloud-init-userdata.yaml:ro"
                -e "CLOUD_INIT_USER_DATA=/cloud-init-userdata.yaml"
            )
            ;;
    esac

    _docker_run_args+=("$DOCKER_VM_RUNNER_IMAGE")
    "${_docker_run_args[@]}" >/dev/null
    _VM_CONTAINER_NAME="$container_name"
    _WATCHDOG_PID=$(_start_vm_container_watchdog "$$" "$container_name")
    log_success "Container started"

    # Wait for cloud-init and SSH
    wait_for_cloud_init "$container_name" "$SSH_READY_TIMEOUT" "$distro" || {
        _e2e_cleanup_vm_container
        cleanup_ssh_key
        return 1
    }
    wait_for_ssh "$SSH_PORT" "$LOGIN_USER" "$SSH_READY_TIMEOUT" "$distro" || {
        _e2e_cleanup_vm_container
        cleanup_ssh_key
        return 1
    }

    # --- Deploy scripts ---
    if [ "$TEST_MODE" = "online" ]; then
        # Online mode: test the production curl | bash flow from GitHub
        log_info "Online mode: testing curl | bash from ${GITHUB_BASE_URL}"
    else
        generate_bundled_scripts
        log_info "Transferring bundled script to VM..."
        vm_scp "$_SETUP_BUNDLE" "/tmp/setup-k8s.sh"
        vm_ssh "chmod +x /tmp/setup-k8s.sh" >/dev/null 2>&1
        rm -f "$_SETUP_BUNDLE"
        log_success "Bundled script deployed to VM"
    fi

    # --- Phase 1: Run setup-k8s.sh ---
    log_info "Starting Kubernetes setup (init)..."
    local setup_args="init"
    [ -n "$k8s_version_flag" ] && setup_args+=" $(printf '%q' "$k8s_version_flag") $(printf '%q' "$k8s_version_val")"
    [ -n "$setup_extra_args_str" ] && setup_args+=" $setup_extra_args_str"

    local setup_cmd
    if [ "$TEST_MODE" = "online" ]; then
        setup_cmd="curl -fsSL ${GITHUB_BASE_URL}/setup-k8s.sh | bash -s -- ${setup_args}"
    else
        setup_cmd="bash /tmp/setup-k8s.sh ${setup_args}"
    fi
    setup_cmd+=" > /tmp/setup-k8s.log 2>&1; echo \$? > /tmp/setup-exit-code"
    vm_ssh "nohup bash -c '${setup_cmd}' </dev/null >/dev/null 2>&1 &"

    # Poll for setup completion
    if ! poll_vm_command vm_ssh "$container_name" /tmp/setup-exit-code /tmp/setup-k8s.log "$TIMEOUT_TOTAL"; then
        vm_ssh "cat /tmp/setup-k8s.log" > "$log_file" 2>/dev/null || true
        _e2e_cleanup_vm_container
        cleanup_ssh_key
        return 1
    fi
    local setup_exit_code="$POLL_EXIT_CODE"
    log_info "Setup completed with exit code: $setup_exit_code"

    if [ "$setup_exit_code" -ne 0 ]; then
        log_error "=== SETUP ERROR LOG ==="
        vm_ssh "cat /tmp/setup-k8s.log" 2>/dev/null || true
        log_error "=== SETUP ERROR LOG END ==="
    fi

    # --- Phase 2: Verify setup ---
    log_info "Verifying Kubernetes components..."
    local kubelet_status
    if vm_ssh "test -x /usr/bin/systemctl || test -x /bin/systemctl" >/dev/null 2>&1; then
        kubelet_status=$(vm_ssh "systemctl is-active kubelet" 2>/dev/null) || kubelet_status="inactive"
    elif vm_ssh "test -x /sbin/rc-service || test -x /usr/sbin/rc-service" >/dev/null 2>&1; then
        if vm_ssh "rc-service kubelet status" >/dev/null 2>&1; then
            kubelet_status="active"
        else
            kubelet_status="inactive"
        fi
    else
        kubelet_status="unknown"
    fi
    kubelet_status=$(echo "$kubelet_status" | tr -d '[:space:]')
    log_info "kubelet: $kubelet_status"

    local kubeconfig_exists="false"
    if vm_ssh "test -f /etc/kubernetes/admin.conf" >/dev/null 2>&1; then
        kubeconfig_exists="true"
    fi

    local api_responsive="false"
    if vm_ssh "timeout 30 kubectl get nodes --kubeconfig=/etc/kubernetes/admin.conf" >/dev/null 2>&1; then
        api_responsive="true"
        log_info "API server is responsive"
    else
        log_info "API server is not responsive"
    fi

    local setup_test_status="failed"
    if [ "$setup_exit_code" -eq 0 ] && [ "$kubelet_status" = "active" ] && [ "$api_responsive" = "true" ]; then
        setup_test_status="success"
        log_success "Setup test: SUCCESS"
    else
        log_error "Setup test: FAILED"
    fi

    # --- Phase 3: Cleanup (only if setup succeeded) ---
    local cleanup_exit_code=0 cleanup_test_status="skipped"
    local services_stopped="unknown" config_cleaned="unknown" packages_removed="unknown"

    if [ "$setup_test_status" = "success" ]; then
        log_info "Starting Kubernetes cleanup..."
        local cleanup_cmd
        if [ "$TEST_MODE" = "online" ]; then
            cleanup_cmd="curl -fsSL ${GITHUB_BASE_URL}/setup-k8s.sh | bash -s -- cleanup --force"
        else
            cleanup_cmd="bash /tmp/setup-k8s.sh cleanup --force"
        fi
        vm_ssh "nohup bash -c '${cleanup_cmd} > /tmp/cleanup-k8s.log 2>&1; echo \$? > /tmp/cleanup-exit-code' </dev/null >/dev/null 2>&1 &"

        if ! poll_vm_command vm_ssh "$container_name" /tmp/cleanup-exit-code /tmp/cleanup-k8s.log "$TIMEOUT_TOTAL"; then
            log_warn "Cleanup polling failed (timeout or container exit)"
            cleanup_exit_code=1
        else
            cleanup_exit_code="$POLL_EXIT_CODE"
        fi
        log_info "Cleanup completed with exit code: $cleanup_exit_code"

        # --- Phase 4: Verify cleanup ---
        log_info "Verifying cleanup..."
        local kubelet_active kubelet_enabled
        if vm_ssh "test -x /usr/bin/systemctl || test -x /bin/systemctl" >/dev/null 2>&1; then
            kubelet_active=$(vm_ssh "systemctl is-active kubelet" 2>/dev/null) || kubelet_active="inactive"
            kubelet_enabled=$(vm_ssh "systemctl is-enabled kubelet" 2>/dev/null) || kubelet_enabled="disabled"
        elif vm_ssh "test -x /sbin/rc-service || test -x /usr/sbin/rc-service" >/dev/null 2>&1; then
            if vm_ssh "rc-service kubelet status" >/dev/null 2>&1; then
                kubelet_active="active"
            else
                kubelet_active="inactive"
            fi
            if vm_ssh "rc-update show default 2>/dev/null | grep -q kubelet" >/dev/null 2>&1; then
                kubelet_enabled="enabled"
            else
                kubelet_enabled="disabled"
            fi
        else
            kubelet_active="inactive"
            kubelet_enabled="disabled"
        fi

        if [ "$(echo "$kubelet_active" | tr -d '[:space:]')" = "active" ] || [ "$(echo "$kubelet_enabled" | tr -d '[:space:]')" = "enabled" ]; then
            services_stopped="false"
        else
            services_stopped="true"
        fi

        if vm_ssh "test -d /etc/kubernetes && ls -A /etc/kubernetes 2>/dev/null | head -1 | grep -q ." >/dev/null 2>&1; then
            config_cleaned="false"
        elif vm_ssh "test -f /etc/default/kubelet" >/dev/null 2>&1; then
            config_cleaned="false"
        else
            config_cleaned="true"
        fi

        packages_removed="true"
        for cmd in kubeadm kubectl kubelet; do
            if vm_ssh "command -v $cmd" >/dev/null 2>&1; then
                packages_removed="false"
                break
            fi
        done

        if [ "$cleanup_exit_code" -eq 0 ] && [ "$services_stopped" = "true" ] && \
           [ "$config_cleaned" = "true" ] && [ "$packages_removed" = "true" ]; then
            cleanup_test_status="success"
            log_success "Cleanup test: SUCCESS"
        else
            cleanup_test_status="failed"
            log_error "Cleanup test: FAILED"
        fi
    else
        log_info "Skipping cleanup test due to setup failure"
    fi

    # --- Retrieve logs ---
    vm_ssh "cat /tmp/setup-k8s.log" > "$log_file" 2>/dev/null || true
    vm_ssh "cat /tmp/cleanup-k8s.log" >> "$log_file" 2>/dev/null || true

    # --- Write test-result.json (on host) ---
    local final_status="failed"
    if [ "$setup_test_status" = "success" ] && [ "$cleanup_test_status" = "success" ]; then
        final_status="success"
    fi

    cat > "results/test-result.json" <<JSONEOF
{
  "status": "$final_status",
  "setup_test": {
    "status": "$setup_test_status",
    "exit_code": $setup_exit_code,
    "kubelet_status": "$kubelet_status",
    "kubeconfig_exists": $kubeconfig_exists,
    "api_responsive": $api_responsive
  },
  "cleanup_test": {
    "status": "$cleanup_test_status",
    "exit_code": $cleanup_exit_code,
    "services_stopped": "$services_stopped",
    "config_cleaned": "$config_cleaned",
    "packages_removed": "$packages_removed"
  },
  "timestamp": "$(date -Iseconds)"
}
JSONEOF

    # Stop container
    _e2e_cleanup_vm_container
    cleanup_ssh_key
    trap - EXIT INT TERM HUP
    [ "$final_status" = "success" ]
}

# Show test results (uses jq if available, falls back to grep/sed)
show_test_results() {
    local distro=$1

    if [ ! -f "results/test-result.json" ]; then
        log_error "Test result not found"
        return 1
    fi

    log_info "Test Results for $distro:"
    echo "=================="

    if ! command -v jq &>/dev/null; then
        log_warn "jq not found; printing raw JSON"
        cat results/test-result.json
        echo ""
        # Match only the top-level "status" key (first occurrence in file)
        local top_status
        top_status=$(sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' results/test-result.json | head -1)
        if [ "$top_status" = "success" ]; then
            return 0
        else
            log_error "Test status is '${top_status:-unknown}' (parsed without jq)"
            return 1
        fi
    fi

    local overall_status setup_status setup_exit_code kubelet_status api_responsive
    local cleanup_status cleanup_exit_code services_stopped config_cleaned packages_removed
    overall_status=$(jq -r '.status // "unknown"' results/test-result.json)
    setup_status=$(jq -r '.setup_test.status // "unknown"' results/test-result.json)
    setup_exit_code=$(jq -r '.setup_test.exit_code // "unknown"' results/test-result.json)
    kubelet_status=$(jq -r '.setup_test.kubelet_status // "unknown"' results/test-result.json)
    api_responsive=$(jq -r '.setup_test.api_responsive // "unknown"' results/test-result.json)
    cleanup_status=$(jq -r '.cleanup_test.status // "unknown"' results/test-result.json)
    cleanup_exit_code=$(jq -r '.cleanup_test.exit_code // "unknown"' results/test-result.json)
    services_stopped=$(jq -r '.cleanup_test.services_stopped // "unknown"' results/test-result.json)
    config_cleaned=$(jq -r '.cleanup_test.config_cleaned // "unknown"' results/test-result.json)
    packages_removed=$(jq -r '.cleanup_test.packages_removed // "unknown"' results/test-result.json)

    echo "Setup Test:"
    echo "  Status: ${setup_status:-unknown}"
    echo "  Exit Code: ${setup_exit_code:-unknown}"
    echo "  Kubelet Status: ${kubelet_status:-unknown}"
    echo "  API Responsive: ${api_responsive:-unknown}"
    echo "Cleanup Test:"
    echo "  Status: ${cleanup_status:-unknown}"
    echo "  Exit Code: ${cleanup_exit_code:-unknown}"
    echo "  Services Stopped: ${services_stopped:-unknown}"
    echo "  Config Cleaned: ${config_cleaned:-unknown}"
    echo "  Packages Removed: ${packages_removed:-unknown}"
    echo "=================="

    if [ "$overall_status" = "success" ]; then
        log_success "Test PASSED for $distro (both setup and cleanup succeeded)"
        return 0
    else
        if [ "$setup_status" != "success" ]; then
            log_error "Setup test FAILED for $distro"
        fi
        if [ "$cleanup_status" != "success" ] && [ "$cleanup_status" != "skipped" ]; then
            log_error "Cleanup test FAILED for $distro"
        fi
        log_error "Test FAILED for $distro"
        return 1
    fi
}

# Test all distributions
test_all() {
    log_info "Starting test for all distributions"
    log_info "Test mode: $TEST_MODE"
    if [ "$TEST_MODE" = "online" ]; then
        log_info "Script source: curl | bash from GitHub"
    else
        log_info "Script source: Bundled (all modules included)"
    fi

    # Get all distributions
    local distros=("${SUPPORTED_DISTROS[@]}")
    local total=${#distros[@]}
    local passed=0
    local failed=0
    local current=0

    # Create summary log file
    local summary_file
    summary_file="results/test-all-summary-$(date +%Y%m%d-%H%M%S).log"
    mkdir -p results

    echo "Testing $total distributions in $TEST_MODE mode" | tee "$summary_file"
    echo "===================" | tee -a "$summary_file"
    echo "Start time: $(date)" | tee -a "$summary_file"
    echo "" | tee -a "$summary_file"

    for distro in "${distros[@]}"; do
        current=$((current + 1))
        echo "" | tee -a "$summary_file"
        echo -e "${BLUE}[$current/$total] Testing: $distro${NC}" | tee -a "$summary_file"
        echo "-----------------------------------" | tee -a "$summary_file"

        local start_time
        start_time=$(date +%s)

        local status
        if run_single_test "$distro"; then
            passed=$((passed + 1))
            status="PASSED"
        else
            failed=$((failed + 1))
            status="FAILED"
        fi

        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))

        echo "$distro: $status (${duration}s)" | tee -a "$summary_file"

        # Add individual test result details to summary
        if [ -f "results/test-result.json" ]; then
            echo "  Details from test-result.json:" >> "$summary_file"
            local s_status="" c_status=""
            if command -v jq &>/dev/null; then
                s_status=$(jq -r '.setup_test.status // "unknown"' results/test-result.json)
                c_status=$(jq -r '.cleanup_test.status // "unknown"' results/test-result.json)
            fi
            echo "    Setup: $s_status, Cleanup: $c_status" >> "$summary_file"
        fi
    done

    # Summary
    echo "" | tee -a "$summary_file"
    echo -e "${BLUE}===== Test Summary =====${NC}" | tee -a "$summary_file"
    echo "Total: $total, Passed: $passed, Failed: $failed" | tee -a "$summary_file"
    echo "End time: $(date)" | tee -a "$summary_file"
    echo "" | tee -a "$summary_file"

    # List all individual log files
    echo "Individual test logs:" | tee -a "$summary_file"
    find results/logs -name '*.log' -printf '  %p\n' 2>/dev/null | sort | tee -a "$summary_file"

    echo "" | tee -a "$summary_file"
    echo "Summary saved to: $summary_file"

    if [ $failed -gt 0 ]; then
        log_error "Some tests failed. Check $summary_file and results/logs/ for details"
        return 1
    else
        log_success "All tests passed!"
        return 0
    fi
}

# Run single test
run_single_test() {
    local distro=$1

    log_info "Starting K8s test for: $distro"
    log_info "Test mode: $TEST_MODE"
    if [ "$TEST_MODE" = "online" ]; then
        log_info "Script source: curl | bash from GitHub"
    else
        log_info "Script source: Bundled (all modules included)"
    fi
    if [ -n "$K8S_VERSION" ]; then
        log_info "Kubernetes version: $K8S_VERSION"
    else
        log_info "Kubernetes version: default (from setup-k8s.sh)"
    fi
    log_info "Working directory: $SCRIPT_DIR"

    local k8s_version_flag="" k8s_version_val=""
    local setup_extra_args_str=""
    if [ -n "$K8S_VERSION" ]; then
        k8s_version_flag="--kubernetes-version"
        k8s_version_val="$K8S_VERSION"
    fi
    if [ ${#SETUP_EXTRA_ARGS[@]} -gt 0 ]; then
        setup_extra_args_str=$(printf '%q ' "${SETUP_EXTRA_ARGS[@]}")
        log_info "Passing extra setup args: $setup_extra_args_str"
    fi

    # Execute each step
    load_config "$distro" || return 1
    prepare_runner_directories || return 1
    run_vm_container "$distro" "$k8s_version_flag" "$k8s_version_val" "$setup_extra_args_str" || return 1

    # Display results and return status
    if show_test_results "$distro"; then
        return 0
    else
        return 1
    fi
}

# Main process
main() {
    local run_all=false
    local distro=""

    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                show_help
                exit 0
                ;;
            --all|-a)
                run_all=true
                shift
                ;;
            --k8s-version)
                _require_arg $# "$1"
                K8S_VERSION="$2"
                shift 2
                ;;
            --online)
                TEST_MODE="online"
                shift
                ;;
            --offline)
                TEST_MODE="offline"
                shift
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
            --setup-args)
                _require_arg $# "$1"
                # Append each word as a separate array element
                # Note: for args containing spaces, use -- syntax instead
                read -r -a _setup_args_tmp <<< "$2"
                SETUP_EXTRA_ARGS+=("${_setup_args_tmp[@]}")
                shift 2
                ;;
            --)
                shift
                # Everything after -- goes into SETUP_EXTRA_ARGS as-is
                while [[ $# -gt 0 ]]; do
                    SETUP_EXTRA_ARGS+=("$1")
                    shift
                done
                ;;
            -*)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                # This should be the distribution name
                distro=$1
                shift
                ;;
        esac
    done

    # Check if we should run all tests
    if [ "$run_all" = true ]; then
        test_all
        exit $?
    fi

    # Check arguments for single test
    if [ -z "$distro" ]; then
        log_error "Distribution name required"
        show_help
        exit 1
    fi

    # Run single test
    if run_single_test "$distro"; then
        exit 0
    else
        exit 1
    fi
}

# Execute script
main "$@"
