#!/usr/bin/env bats
# Ported from test/unit/test_status.sh

setup() {
    load '../helpers/common'
}

# ============================================================
# Test: STATUS_OUTPUT_FORMAT default
# ============================================================
_case_status_output_format_default() {
    echo "=== Test: STATUS_OUTPUT_FORMAT default ==="
    (
        load_modules
        _assert_eq "STATUS_OUTPUT_FORMAT default" "text" "$STATUS_OUTPUT_FORMAT"
    )
}

# ============================================================
# Test: parse_status_args
# ============================================================
_case_parse_status_args() {
    echo "=== Test: parse_status_args ==="
    (
        load_modules

        parse_status_args --output wide
        _assert_eq "STATUS_OUTPUT_FORMAT parsed" "wide" "$STATUS_OUTPUT_FORMAT"
    )
}

# ============================================================
# Test: parse_status_args rejects invalid --output
# ============================================================
_case_parse_status_args_invalid_output() {
    echo "=== Test: parse_status_args rejects invalid --output ==="
    (
        load_modules

        local exit_code=0
        (parse_status_args --output json) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "invalid --output rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: parse_status_args rejects unknown option
# ============================================================
_case_parse_status_unknown_option() {
    echo "=== Test: parse_status_args unknown option ==="
    (
        _load_status_ssh_test_modules

        local exit_code=0
        (parse_status_args --bogus-flag) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "unknown option rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: status --help exits 0
# ============================================================
_case_status_help_exit() {
    echo "=== Test: status --help exits 0 ==="
    _assert_exit_code "setup-k8s.sh status --help exits 0" 0 bash "$PROJECT_ROOT/setup-k8s.sh" status --help
}

# File-local module loaders
_load_status_test_modules() {
    load_modules
}

_load_status_ssh_test_modules() {
    _load_status_test_modules
}

@test "STATUS_OUTPUT_FORMAT default" {
    _case_status_output_format_default
}

@test "parse_status_args" {
    _case_parse_status_args
}

@test "parse_status_args rejects invalid --output" {
    _case_parse_status_args_invalid_output
}

@test "parse_status_args unknown option" {
    _case_parse_status_unknown_option
}

@test "status --help exits 0" {
    _case_status_help_exit
}

# --- exit status reflects the node's health ---

_fake_node() {
    _STATUS_K8S_DIR="$BATS_TEST_TMPDIR/kubernetes"
    mkdir -p "$_STATUS_K8S_DIR/manifests"
    UP="${UP:-kubelet containerd}"
    _service_is_active() { case " $UP " in *" $1 "*) return 0 ;; esac; return 1; }
    for b in kubeadm kubelet; do fake_cmd "$b" 0 "v1.37.2"; done
    fake_cmd kubectl "${API_RC:-0}" ""
    unset KUBECONFIG
}

@test "status exits 2 when Kubernetes is not set up" {
    load_modules; quiet_logs
    _STATUS_K8S_DIR="$BATS_TEST_TMPDIR/none"
    command() { if [ "$1" = -v ] && [ "$2" = kubeadm ]; then return 1; fi; builtin command "$@"; }
    run status_local
    [ "$status" -eq 2 ]
}

@test "status exits 0 for a healthy control plane" {
    load_modules; quiet_logs; _fake_node
    touch "$_STATUS_K8S_DIR/manifests/kube-apiserver.yaml" "$_STATUS_K8S_DIR/admin.conf"
    run status_local
    [ "$status" -eq 0 ]
}

@test "status exits 1 when kubelet or the runtime is stopped" {
    load_modules; quiet_logs
    UP="containerd" _fake_node
    touch "$_STATUS_K8S_DIR/kubelet.conf"
    run status_local
    [ "$status" -eq 1 ]
    UP="kubelet" _fake_node
    run status_local
    [ "$status" -eq 1 ]
}

@test "status exits 1 when the API server does not answer" {
    load_modules; quiet_logs
    API_RC=1 _fake_node
    touch "$_STATUS_K8S_DIR/manifests/kube-apiserver.yaml" "$_STATUS_K8S_DIR/admin.conf"
    run status_local
    [ "$status" -eq 1 ]
}

@test "status on a worker without a kubeconfig checks the services only" {
    load_modules; quiet_logs; _fake_node
    touch "$_STATUS_K8S_DIR/kubelet.conf"
    run status_local
    [ "$status" -eq 0 ]
    if fake_calls | grep -q '^kubectl --kubeconfig'; then return 1; fi
}

@test "status --output wide reads CIDRs from the manifests" {
    load_modules; _fake_node
    touch "$_STATUS_K8S_DIR/admin.conf"
    printf '    - --cluster-cidr=10.244.0.0/16\n' > "$_STATUS_K8S_DIR/manifests/kube-controller-manager.yaml"
    printf '    - --service-cluster-ip-range=10.96.0.0/12\n' > "$_STATUS_K8S_DIR/manifests/kube-apiserver.yaml"
    _find_etcd_container() { echo cid; }
    _etcdctl_exec() { echo "127.0.0.1:2379 is healthy"; }
    STATUS_OUTPUT_FORMAT=wide
    run status_local
    [ "$status" -eq 0 ]
    [[ "$output" == *"Pod CIDR: 10.244.0.0/16"* ]]
    [[ "$output" == *"Service CIDR: 10.96.0.0/12"* ]]
}
