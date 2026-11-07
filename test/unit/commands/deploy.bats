#!/usr/bin/env bats
# shellcheck disable=SC2034 # tests set globals read by the modules under test
# Ported from test/unit/test_deploy.sh

setup() {
    load '../helpers/common'
}

# File-local module loader
_load_deploy_test_modules() {
    load_modules
}

# ============================================================
# Test: --swap-enabled deploy passthrough
# ============================================================
_case_deploy_parse_swap_enabled() {
    echo "=== Test: parse_deploy_args --swap-enabled passthrough ==="
    (
        _load_deploy_test_modules

        parse_deploy_args --control-planes 10.0.0.1 --swap-enabled
        local has_swap="false"
        for arg in "${DEPLOY_PASSTHROUGH_ARGS[@]}"; do
            if [ "$arg" = "--swap-enabled" ]; then has_swap="true"; break; fi
        done
        _assert_eq "swap-enabled in passthrough" "true" "$has_swap"
    )
}

# ============================================================
# Test: _download_binary fails on invalid URL
# ============================================================
_case_download_binary_failure() {
    echo "=== Test: _download_binary fails on invalid URL ==="
    (
        load_modules

        local exit_code=0
        local tmp
        tmp=$(mktemp -t test-dl-XXXXXX)
        (_download_binary "https://invalid.example.com/nonexistent" "$tmp") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "_download_binary fails on invalid URL" "0" "$exit_code"
        rm -f "$tmp"
    )
}

# ============================================================
# Test: DEPLOY_REMOTE_TIMEOUT / DEPLOY_POLL_INTERVAL defaults
# ============================================================
# ============================================================
# Test: DEPLOY_REMOTE_TIMEOUT / DEPLOY_POLL_INTERVAL defaults
# ============================================================
_case_deploy_timeout_defaults() {
    echo "=== Test: DEPLOY_REMOTE_TIMEOUT / DEPLOY_POLL_INTERVAL defaults ==="
    (
        load_modules
        _assert_eq "DEPLOY_REMOTE_TIMEOUT default" "600" "$DEPLOY_REMOTE_TIMEOUT"
        _assert_eq "DEPLOY_POLL_INTERVAL default" "10" "$DEPLOY_POLL_INTERVAL"
    )
}

@test "parse_deploy_args --swap-enabled passthrough" {
    _case_deploy_parse_swap_enabled
}

@test "_download_binary fails on invalid URL" {
    _case_download_binary_failure
}

@test "DEPLOY_REMOTE_TIMEOUT / DEPLOY_POLL_INTERVAL defaults" {
    _case_deploy_timeout_defaults
}

@test "deploy saves the admin kubeconfig of the first control plane (mode 600)" {
    load_modules; quiet_logs
    cd "$BATS_TEST_TMPDIR" || return 1
    _deploy_ssh() { case "$3" in "sudo -n cat /etc/kubernetes/admin.conf") printf 'apiVersion: v1\nkind: Config\nclusters: []\n' ;; *) return 1 ;; esac; }
    _deploy_save_kubeconfig ubuntu 10.0.0.1
    grep -qx 'kind: Config' kubeconfig
    [ "$(stat -c %a kubeconfig)" = 600 ]
    # Unreadable admin.conf: nothing written
    rm -f kubeconfig
    _deploy_ssh() { return 1; }
    run _deploy_save_kubeconfig ubuntu 10.0.0.1
    [ "$status" -ne 0 ] && [ ! -e kubeconfig ]
}

# Fake cluster for deploy_cluster. EXISTING=true: the first control plane
# runs a cluster whose nodes are listed in $MEMBERS; runs are recorded in $RUNS.
_fake_deploy() {
    load_modules
    cd "$BATS_TEST_TMPDIR" || return 1
    RUNS="$BATS_TEST_TMPDIR/runs"; : > "$RUNS"
    remote_session_open() { :; }
    remote_session_close() { :; }
    _audit_log() { :; }
    _extract_join_info() { _JOIN_TOKEN=t _JOIN_ADDR=10.0.0.1:6443 _JOIN_HASH=h _CERT_KEY=k; }
    _deploy_pin_proxy_mode() { :; }
    _verify_deployed_cluster() { :; }
    _deploy_save_kubeconfig() { :; }
    sleep() { :; }
    remote_exec() {
        case "$2" in
            "test -f /etc/kubernetes/admin.conf") [ "${EXISTING:-false}" = true ] ;;
            *readyz*) [ "${API_UP:-true}" = true ] ;;
        esac
    }
    _get_node_name() { case " ${MEMBERS:-} " in *" $3 "*) echo "n-$3"; return 0 ;; esac; return 1; }
    _deploy_remote_run() { _parse_node_address "$2"; echo "$3 $_NODE_HOST" >> "$RUNS"; }
    DEPLOY_SSH_USER=root
}

@test "a new cluster: init on the first control plane, joins for the others" {
    _fake_deploy
    DEPLOY_CONTROL_PLANES=10.0.0.1 DEPLOY_WORKERS=10.0.0.11,10.0.0.12
    run deploy_cluster
    [ "$status" -eq 0 ]
    [ "$(sort "$RUNS")" = "$(printf '%s\n' 'join worker 10.0.0.11' 'join worker 10.0.0.12' 'kubeadm init 10.0.0.1')" ]
}

@test "a rerun on an existing cluster joins only the nodes not in it" {
    _fake_deploy
    EXISTING=true MEMBERS="10.0.0.1 10.0.0.2 10.0.0.11"
    DEPLOY_CONTROL_PLANES=10.0.0.1,10.0.0.2,10.0.0.3 DEPLOY_WORKERS=10.0.0.11,10.0.0.12
    DEPLOY_PASSTHROUGH_ARGS=$(printf '%s\n%s' --ha-vip 10.0.0.100)
    touch kubeconfig
    run deploy_cluster
    [ "$status" -eq 0 ]
    [ "$(sort "$RUNS")" = "$(printf '%s\n' 'join control-plane 10.0.0.3' 'join worker 10.0.0.12')" ]
}

@test "a new cluster is not deployed over an existing ./kubeconfig" {
    _fake_deploy
    touch kubeconfig
    DEPLOY_CONTROL_PLANES=10.0.0.1
    run deploy_cluster
    [ "$status" -ne 0 ]
    [[ "$output" == *"./kubeconfig already exists"* ]]
    [ ! -s "$RUNS" ]
}

@test "an initialized control plane whose API server does not answer stops the deploy" {
    _fake_deploy
    EXISTING=true API_UP=false
    DEPLOY_CONTROL_PLANES=10.0.0.1 DEPLOY_WORKERS=10.0.0.11
    run deploy_cluster
    [ "$status" -ne 0 ]
    [ ! -s "$RUNS" ]
}
