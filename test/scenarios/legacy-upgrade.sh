#!/bin/bash
#
# Upgrade from the previous setup-k8s E2E test via docker-vm-runner.
# Sets a node up with an earlier setup-k8s version (downloaded from GitHub),
# then manages it with the current code: upgrade, cleanup, and a fresh init.
# Checks that cleanup leaves no packages, package locks, repositories, or
# keys behind, including the ones only the earlier version created.
#
# Usage: ./test/scenarios/legacy-upgrade.sh [--distro <name>] [--legacy-ref <git ref>]
#            [--from-version <MAJOR.MINOR>] [--to-version <MAJOR.MINOR.PATCH>] [--no-upgrade]
#
# --no-upgrade skips the upgrade step (distributions that install Kubernetes
# from their own packages ship one version, e.g. Arch and Alpine).
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
# Last version distributed from raw/main before the release asset
LEGACY_REF="${LEGACY_REF:-1b40290ee9dee8cd0931e0846218395239f5979e}"
FROM_VERSION=""
TO_VERSION=""
DO_UPGRADE=true

DOCKER_NETWORK="${DOCKER_NETWORK:-k8s-legacy-net-$$}"
DOCKER_SUBNET="${DOCKER_SUBNET:-10.211.0.0/24}"
CP_DOCKER_IP="${CP_DOCKER_IP:-10.211.0.10}"

SSH_KEY_DIR=""
_init_test_defaults

show_help() {
    cat <<EOF
Upgrade-from-previous-version E2E Test

Usage: $0 [OPTIONS]

Options:
  --distro <name>          Distribution to test (default: $DISTRO)
  --legacy-ref <ref>       Earlier setup-k8s git ref (default: $LEGACY_REF)
  --from-version <ver>     Kubernetes MAJOR.MINOR installed by the earlier version (default: previous minor)
  --to-version <ver>       Kubernetes MAJOR.MINOR.PATCH to upgrade to (default: latest stable)
  --no-upgrade             Skip the upgrade step
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
        if _root "kubectl --kubeconfig=/etc/kubernetes/admin.conf get --raw=/readyz" >/dev/null 2>&1; then
            return 0
        fi
        sleep 5
        tries=$((tries + 1))
    done
    return 1
}

# Print what cleanup left behind (empty when clean).
_leftovers() {
    _root 'for b in kubeadm kubelet kubectl; do command -v "$b" >/dev/null 2>&1 && echo "binary:$b"; done
        if command -v dpkg-query >/dev/null 2>&1; then
            for p in kubeadm kubelet kubectl cri-tools kubernetes-cni cri-o; do
                dpkg-query -W -f="\${Status}" "$p" 2>/dev/null | grep -q " installed$" && echo "package:$p"
            done
        fi
        if command -v rpm >/dev/null 2>&1; then
            for p in kubeadm kubelet kubectl cri-tools kubernetes-cni cri-o; do
                rpm -q "$p" >/dev/null 2>&1 && echo "package:$p"
            done
        fi
        if command -v pacman >/dev/null 2>&1; then
            for p in kubeadm kubelet kubectl kubeadm-bin kubelet-bin kubectl-bin; do
                pacman -Q "$p" >/dev/null 2>&1 && echo "package:$p"
            done
        fi
        if command -v apk >/dev/null 2>&1; then
            for p in kubeadm kubelet kubectl; do
                apk info -e "$p" >/dev/null 2>&1 && echo "package:$p"
            done
        fi
        if command -v dnf >/dev/null 2>&1 && dnf versionlock list >/dev/null 2>&1; then
            dnf versionlock list 2>/dev/null | grep -E "^(kube|cri-tools)" | sed "s/^/versionlock:/"
        fi
        if command -v zypper >/dev/null 2>&1; then
            zypper --non-interactive locks 2>/dev/null | grep -o -E "kube(adm|let|ctl)" | sort -u | sed "s/^/zypper-lock:/"
        fi
        for f in /etc/yum.repos.d/kubernetes.repo /etc/yum.repos.d/cri-o.repo /etc/yum.repos.d/docker-ce.repo \
                 /etc/yum.repos.d/docker.repo /etc/apt/sources.list.d/kubernetes.list /etc/apt/sources.list.d/cri-o.list \
                 /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/kubernetes-apt-keyring.gpg \
                 /etc/apt/keyrings/crio-apt-keyring.gpg /etc/apt/keyrings/kubernetes.gpg /etc/apt/keyrings/cri-o.gpg \
                 /etc/apt/keyrings/docker.gpg /etc/zypp/repos.d/kubernetes.repo /etc/zypp/repos.d/cri-o.repo; do
            [ -e "$f" ] && echo "file:$f"
        done
        true' 2>/dev/null
}

_resolve_versions() {
    local stable major minor
    [ -n "$TO_VERSION" ] && [ -n "$FROM_VERSION" ] && return 0
    stable=$(curl -fsSL --retry 3 --retry-delay 2 https://dl.k8s.io/release/stable.txt | sed 's/^v//')
    major=$(echo "$stable" | cut -d. -f1)
    minor=$(echo "$stable" | cut -d. -f2)
    [ -n "$TO_VERSION" ] || TO_VERSION="$stable"
    [ -n "$FROM_VERSION" ] || FROM_VERSION="${major}.$((minor - 1))"
}

run_legacy_test() {
    _test_preamble "legacy-upgrade" "$DISTRO"
    local cp_container="k8s-legacy-${DISTRO}-${_TEST_TS}"
    ALL_PASS=true

    trap '_cleanup_single_cp' EXIT INT TERM HUP
    create_single_cp_env "$cp_container" "legacy" "k8s-legacy-test" "k8s-legacy-test" || return 1

    local legacy_tar
    legacy_tar=$(mktemp /tmp/setup-k8s-legacy.XXXXXX.tar.gz)
    if ! curl -fsSL --retry 3 -o "$legacy_tar" "https://github.com/MuNeNiCK/setup-k8s/archive/${LEGACY_REF}.tar.gz"; then
        log_error "Failed to download setup-k8s ${LEGACY_REF}"
        rm -f "$legacy_tar"
        return 1
    fi
    scp "${SSH_OPTS[@]}" -P "$_CP_SSH_PORT" "$legacy_tar" "root@localhost:/root/legacy.tar.gz" >/dev/null
    scp "${SSH_OPTS[@]}" -P "$_CP_SSH_PORT" "$HOST_BUNDLE" "root@localhost:/root/setup-k8s.sh" >/dev/null
    rm -f "$legacy_tar"
    _root "mkdir -p /root/legacy && tar -xzf /root/legacy.tar.gz -C /root/legacy --strip-components=1"

    local legacy_args="" new_init_args=""
    if [ "$DO_UPGRADE" = true ]; then
        _resolve_versions
        log_info "Kubernetes: ${FROM_VERSION} (earlier setup-k8s) -> ${TO_VERSION} (current)"
        legacy_args="--kubernetes-version $FROM_VERSION"
        new_init_args="--kubernetes-version $TO_VERSION"
    fi

    # 1. Earlier version: init
    _run_step "init with setup-k8s ${LEGACY_REF:0:7}" "sh /root/legacy/setup-k8s.sh init $legacy_args" || true
    _check "API server is ready after the earlier init" _api_ready

    # 2. Current version: upgrade
    if [ "$DO_UPGRADE" = true ]; then
        _run_step "upgrade to ${TO_VERSION}" \
            "sh /root/setup-k8s.sh upgrade --kubernetes-version $TO_VERSION --first-control-plane --skip-drain --no-rollback" || true
        local got
        got=$(_root "kubeadm version -o short; kubelet --version" 2>/dev/null | tr '\n' ' ')
        if [ "$got" = "v${TO_VERSION} Kubernetes v${TO_VERSION} " ]; then
            log_success "CHECK: kubeadm and kubelet are at v${TO_VERSION}"
        else
            log_error "CHECK: versions after upgrade: ${got}(expected v${TO_VERSION})"
            ALL_PASS=false
        fi
        _check "API server is ready after the upgrade" _api_ready
    fi

    # 3. Current version: cleanup removes everything, including legacy artifacts
    _run_step "cleanup" "sh /root/setup-k8s.sh cleanup --force" || true
    local left
    left=$(_leftovers)
    if [ -z "$left" ]; then
        log_success "CHECK: nothing left behind after cleanup"
    else
        log_error "CHECK: left behind after cleanup: $(echo "$left" | tr '\n' ' ')"
        ALL_PASS=false
    fi

    # 4. The node can be set up again with the current version
    # shellcheck disable=SC2086 # new_init_args is empty or two words
    _run_step "init with the current version" "sh /root/setup-k8s.sh init $new_init_args" || true
    _check "API server is ready after the new init" _api_ready
    _run_step "final cleanup" "sh /root/setup-k8s.sh cleanup --force" || true

    _test_result "LEGACY-UPGRADE" "$ALL_PASS" _cleanup_single_cp "$cp_container" "$_CP_SSH_PORT"
}

while [[ $# -gt 0 ]]; do
    if _parse_common_test_args "$@"; then shift "$SHIFT_COUNT"; continue; fi
    case $1 in
        --legacy-ref) _require_arg $# "$1"; LEGACY_REF="$2"; shift 2 ;;
        --from-version) _require_arg $# "$1"; FROM_VERSION="$2"; shift 2 ;;
        --to-version) _require_arg $# "$1"; TO_VERSION="$2"; shift 2 ;;
        --no-upgrade) DO_UPGRADE=false; shift ;;
        --help|-h) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

if run_legacy_test; then
    exit 0
else
    exit 1
fi
