#!/bin/bash
#
# HTTP proxy E2E test via docker-vm-runner.
# Runs a proxy (tinyproxy) inside the VM and blocks every direct outbound
# connection to ports 80 and 443 except the proxy's, then sets up and
# cleans up with --http-proxy/--https-proxy. Anything that bypasses the
# proxy (package manager, downloads, image pulls by the container runtime)
# makes the setup fail. Checks that the runtime runs with the proxy, that the
# proxy carried the image pulls, that cluster traffic does not use it, and
# that cleanup removes the proxy settings.
#
# Usage: ./test/scenarios/proxy.sh [--distro <name>] [--setup-args "ARGS"]
#

set -euo pipefail

SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(cd "$SCENARIO_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
SCRIPT_DIR="$TEST_DIR"
# shellcheck source=test/lib/runner.sh
source "$TEST_DIR/lib/runner.sh"
cd "$TEST_DIR"

# shellcheck disable=SC2034 # read by the harness
SETUP_K8S_SCRIPT="$PROJECT_ROOT/setup-k8s.sh"
DOCKER_VM_RUNNER_IMAGE="${DOCKER_VM_RUNNER_IMAGE:-ghcr.io/munenick/docker-vm-runner:latest}"
VM_DATA_DIR="${VM_DATA_DIR:-$SCRIPT_DIR/data}"

DISTRO="${DISTRO:-ubuntu-24.04-cloud-amd64}"
K8S_VERSION=""
SETUP_EXTRA_ARGS=""
PROXY_URL="http://127.0.0.1:8888"

DOCKER_NETWORK="${DOCKER_NETWORK:-k8s-proxy-net-$$}"
DOCKER_SUBNET="${DOCKER_SUBNET:-10.212.0.0/24}"
CP_DOCKER_IP="${CP_DOCKER_IP:-10.212.0.10}"

SSH_KEY_DIR=""
_init_test_defaults

show_help() {
    cat <<EOF
HTTP Proxy E2E Test

Usage: $0 [OPTIONS]

Options:
  --distro <name>          Distribution to test (default: $DISTRO)
  --setup-args ARGS        Extra args for setup-k8s.sh init (e.g. "--cri crio")
  --memory <MB>            VM memory (default: $VM_MEMORY)
  --cpus <count>           VM CPUs (default: $VM_CPUS)
  --disk-size <size>       VM disk size (default: $VM_DISK_SIZE)
  --help, -h               Show this help message
EOF
}

_root() { vm_ssh_root "$_CP_SSH_PORT" "$@"; }

_check() {
    local desc="$1"; shift
    if "$@"; then
        log_success "CHECK: $desc"
    else
        log_error "CHECK: $desc"
        ALL_PASS=false
    fi
}

_run_step() {
    local desc="$1" cmd="$2" rc=0
    log_info "$desc: $cmd"
    _root "$cmd" >> "$_TEST_LOG_FILE" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        log_success "CHECK: $desc succeeded"
    else
        log_error "CHECK: $desc failed (exit $rc)"
        ALL_PASS=false
    fi
    return "$rc"
}

_api_ready() {
    local tries=0
    while [ "$tries" -lt 60 ]; do
        _root "kubectl --kubeconfig=/etc/kubernetes/admin.conf get --raw=/readyz" >/dev/null 2>&1 && return 0
        sleep 5
        tries=$((tries + 1))
    done
    return 1
}

# Install and start tinyproxy (listens on 127.0.0.1:8888) and nftables
_setup_proxy() {
    _root 'set -e
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tinyproxy nftables
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y -q epel-release >/dev/null 2>&1 || true
            dnf install -y -q tinyproxy nftables
        elif command -v zypper >/dev/null 2>&1; then
            zypper --non-interactive install tinyproxy nftables
        elif command -v apk >/dev/null 2>&1; then
            apk add -q tinyproxy nftables
        elif command -v pacman >/dev/null 2>&1; then
            pacman -Sy --noconfirm tinyproxy nftables
        fi
        conf=$(ls /etc/tinyproxy/tinyproxy.conf /etc/tinyproxy.conf 2>/dev/null | head -n 1)
        sed -i "s/^#*Port .*/Port 8888/; s/^#*LogLevel .*/LogLevel Info/" "$conf"
        grep -q "^Allow 127.0.0.1" "$conf" || echo "Allow 127.0.0.1" >> "$conf"
        if command -v systemctl >/dev/null 2>&1; then systemctl restart tinyproxy; else rc-service tinyproxy restart; fi'
}

# Reject direct connections to ports 80/443 outside private networks, except
# those of the proxy (a separate nftables table: iptables resets keep it)
_block_direct_egress() {
    _root 'uid=$(id -u tinyproxy 2>/dev/null || id -u nobody)
        nft -f - <<EOF
table inet setup_k8s_proxy_test {
    chain output {
        type filter hook output priority 0; policy accept;
        meta skuid $uid accept
        ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 127.0.0.0/8 } accept
        ip6 daddr { ::1, fc00::/7, fe80::/10 } accept
        tcp dport { 80, 443 } reject with tcp reset
    }
}
EOF'
}

_direct_access_blocked() {
    ! _root "curl -fsS --max-time 15 https://dl.k8s.io/release/stable.txt" >/dev/null 2>&1
}

run_proxy_test() {
    _test_preamble "proxy" "$DISTRO"
    local cp_container="k8s-proxy-${DISTRO}-${_TEST_TS}"
    ALL_PASS=true

    trap '_cleanup_single_cp' EXIT INT TERM HUP
    create_single_cp_env "$cp_container" "proxy" "k8s-proxy-test" "k8s-proxy-test" || return 1
    scp "${SSH_OPTS[@]}" -P "$_CP_SSH_PORT" "$HOST_BUNDLE" "root@localhost:/root/setup-k8s.sh" >/dev/null

    _setup_proxy >> "$_TEST_LOG_FILE" 2>&1 || { log_error "Could not set up tinyproxy in the VM"; return 1; }
    _block_direct_egress >> "$_TEST_LOG_FILE" 2>&1 || { log_error "Could not block direct egress"; return 1; }

    # The block works: direct access fails, access through the proxy works
    _check "direct HTTPS access is blocked" _direct_access_blocked
    _check "HTTPS access through the proxy works" \
        _root "curl -fsS --max-time 30 -x $PROXY_URL https://dl.k8s.io/release/stable.txt >/dev/null"

    local proxy_args="--http-proxy $PROXY_URL --https-proxy $PROXY_URL"
    _run_step "init behind the proxy" "sh /root/setup-k8s.sh init $proxy_args $SETUP_EXTRA_ARGS" || true
    _check "API server is ready (cluster traffic does not use the proxy)" _api_ready

    local runtime=containerd
    [[ " $SETUP_EXTRA_ARGS " == *" --cri crio "* ]] && runtime=crio
    _check "${runtime} runs with HTTPS_PROXY" \
        _root "tr '\\0' '\\n' < /proc/\$(pidof $runtime | cut -d' ' -f1)/environ | grep -qx 'HTTPS_PROXY=$PROXY_URL'"
    _check "NO_PROXY of ${runtime} contains the node address and the Service network" \
        _root "e=\$(tr '\\0' '\\n' < /proc/\$(pidof $runtime | cut -d' ' -f1)/environ | sed -n 's/^NO_PROXY=//p'); \
               ip=\$(ip -4 route get 1.1.1.1 | awk '{for (i=1;i<=NF;i++) if (\$i==\"src\") print \$(i+1)}'); \
               case \",\$e,\" in *\",\$ip,\"*) ;; *) exit 1 ;; esac; case \",\$e,\" in *,10.96.0.0/12,*) ;; *) exit 1 ;; esac"
    if _root "{ cat /var/log/tinyproxy/*.log 2>/dev/null; journalctl -u tinyproxy --no-pager 2>/dev/null; } | grep -q 'registry.k8s.io'"; then
        log_success "CHECK: the proxy log shows registry.k8s.io"
    else
        log_error "CHECK: the proxy log does not show registry.k8s.io"
        ALL_PASS=false
    fi

    _run_step "cleanup" "sh /root/setup-k8s.sh cleanup --force" || true
    verify_no_leftovers _root || ALL_PASS=false

    _test_result "PROXY" "$ALL_PASS" _cleanup_single_cp "$cp_container" "$_CP_SSH_PORT"
}

while [[ $# -gt 0 ]]; do
    if _parse_common_test_args "$@"; then shift "$SHIFT_COUNT"; continue; fi
    case $1 in
        --setup-args) _require_arg $# "$1"; SETUP_EXTRA_ARGS="$2"; shift 2 ;;
        --help|-h) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

if run_proxy_test; then
    exit 0
else
    exit 1
fi
