#!/bin/bash
#
# Init options E2E test via docker-vm-runner.
# Deploys a single control plane from the host with options that change the
# generated configuration, then checks the result on the node:
#   - --kubernetes-version MAJOR.MINOR.PATCH pins packages and control plane
#   - default --proxy-mode auto selects nftables on a current kernel
#   - --kubeadm-patches (local directory copied to the node) is applied
#   - --image-repository is written to the kubeadm configuration
#   - --install-helm / --install-kustomize install the pinned versions
#   - the pause image of the runtime matches the installed kubeadm
#
# Usage: ./test/scenarios/options.sh [--distro <name>] [--k8s-version <MAJOR.MINOR.PATCH>]
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
K8S_VERSION="1.37.1"
IMAGE_REPOSITORY="registry.k8s.io"
HELM_VERSION="${HELM_VERSION:-4.3.1}"
KUSTOMIZE_VERSION="${KUSTOMIZE_VERSION:-5.8.3}"

DOCKER_NETWORK="${DOCKER_NETWORK:-k8s-options-net-$$}"
DOCKER_SUBNET="${DOCKER_SUBNET:-10.210.0.0/24}"
CP_DOCKER_IP="${CP_DOCKER_IP:-10.210.0.10}"

SSH_KEY_DIR=""
_init_test_defaults

show_help() {
    cat <<EOF
Init Options E2E Test

Usage: $0 [OPTIONS]

Options:
  --distro <name>         Distribution to test (default: $DISTRO)
  --k8s-version <ver>     Kubernetes patch version to pin (default: $K8S_VERSION)
  --memory <MB>           VM memory (default: $VM_MEMORY)
  --cpus <count>          VM CPUs (default: $VM_CPUS)
  --disk-size <size>      VM disk size (default: $VM_DISK_SIZE)
  --help, -h              Show this help message
EOF
}

_root() { vm_ssh_root "$_CP_SSH_PORT" "$@"; }
_kubectl() { _root "kubectl --kubeconfig=/etc/kubernetes/admin.conf $*"; }

_check_eq() {
    local desc="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then
        log_success "CHECK: $desc = $got"
    else
        log_error "CHECK: $desc = '$got' (expected '$want')"
        ALL_PASS=false
    fi
}

run_options_test() {
    _test_preamble "options" "$DISTRO"
    local cp_container="k8s-options-${DISTRO}-${_TEST_TS}"
    ALL_PASS=true

    trap '_cleanup_single_cp' EXIT INT TERM HUP
    create_single_cp_env "$cp_container" "options" "k8s-options-test" "k8s-options-test" || return 1

    # kubeadm patch: annotate the kube-apiserver static Pod
    local patches
    patches=$(mktemp -d /tmp/setup-k8s-patches.XXXXXX)
    cat > "$patches/kube-apiserver+strategic.yaml" <<'EOF'
metadata:
  annotations:
    setup-k8s.test/patched: "true"
EOF

    log_info "=== Running deploy with options ==="
    local deploy_cmd=(
        sh "$HOST_BUNDLE" deploy
        --control-planes "$CP_DOCKER_IP"
        --ssh-user root --ssh-port 2222
        --ssh-key "$SSH_KEY_DIR/id_test" --ssh-host-key-check accept-new
        --kubernetes-version "$K8S_VERSION"
        --image-repository "$IMAGE_REPOSITORY"
        --kubeadm-patches "$patches"
        --install-helm true --install-kustomize true
    )
    log_info "Command: ${deploy_cmd[*]}"
    local deploy_exit=0
    run_with_timeout deploy_exit "$_TEST_LOG_FILE" "${deploy_cmd[@]}"
    rm -rf "$patches"
    _check_eq "deploy exit code" 0 "$deploy_exit"

    _check_eq "kubeadm version" "v${K8S_VERSION}" "$(_root "kubeadm version -o short" 2>/dev/null)"
    _check_eq "kubelet version" "Kubernetes v${K8S_VERSION}" "$(_root "kubelet --version" 2>/dev/null)"
    _check_eq "kube-apiserver image" "${IMAGE_REPOSITORY}/kube-apiserver:v${K8S_VERSION}" \
        "$(_kubectl "-n kube-system get pod -l component=kube-apiserver -o jsonpath='{.items[0].spec.containers[0].image}'" 2>/dev/null)"
    _check_eq "kube-proxy mode (auto)" "nftables" \
        "$(_kubectl "-n kube-system get configmap kube-proxy -o jsonpath='{.data.config\\.conf}'" 2>/dev/null | awk '/^mode:/ {print $2}' | tr -d '"')"
    _check_eq "imageRepository in kubeadm-config" "$IMAGE_REPOSITORY" \
        "$(_kubectl "-n kube-system get configmap kubeadm-config -o jsonpath='{.data.ClusterConfiguration}'" 2>/dev/null | awk '/^imageRepository:/ {print $2}')"
    _check_eq "kubeadm patch applied" "true" \
        "$(_root "grep -q 'setup-k8s.test/patched' /etc/kubernetes/manifests/kube-apiserver.yaml && echo true || echo false" 2>/dev/null)"

    local want_pause got_pause
    want_pause=$(_root "kubeadm config images list --kubernetes-version v${K8S_VERSION} 2>/dev/null | grep /pause:" 2>/dev/null)
    got_pause=$(_root "grep -E '^\\s*(sandbox_image|sandbox) *=' /etc/containerd/config.toml | head -1" 2>/dev/null \
        | sed -E "s/^[^=]*= *//; s/[\"' ]//g")
    _check_eq "runtime pause image" "$want_pause" "$got_pause"

    _check_eq "helm version" "v${HELM_VERSION}" "$(_root "/usr/local/bin/helm version --template '{{.Version}}'" 2>/dev/null)"
    _check_eq "kustomize version" "v${KUSTOMIZE_VERSION}" "$(_root "/usr/local/bin/kustomize version" 2>/dev/null | tr -d '[:space:]')"

    _test_result "OPTIONS" "$ALL_PASS" _cleanup_single_cp "$cp_container" "$_CP_SSH_PORT"
}

while [[ $# -gt 0 ]]; do
    if _parse_common_test_args "$@"; then shift "$SHIFT_COUNT"; continue; fi
    case $1 in
        --help|-h) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

if run_options_test; then
    exit 0
else
    exit 1
fi
