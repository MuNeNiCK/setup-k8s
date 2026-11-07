#!/usr/bin/env bats
# shellcheck disable=SC2034 # tests set globals read by the modules under test
# Ported from test/unit/test_upgrade.sh

setup() {
    load '../helpers/common'
}

# ============================================================
# Test: UPGRADE_* variable defaults
# ============================================================
_case_upgrade_variables_defaults() {
    echo "=== Test: UPGRADE_* variable defaults ==="
    (
        load_modules
        _assert_eq "UPGRADE_TARGET_VERSION default" "" "$UPGRADE_TARGET_VERSION"
        _assert_eq "UPGRADE_FIRST_CONTROL_PLANE default" "false" "$UPGRADE_FIRST_CONTROL_PLANE"
        _assert_eq "UPGRADE_SKIP_DRAIN default" "false" "$UPGRADE_SKIP_DRAIN"
    )
}

# ============================================================
# Test: parse_upgrade_local_args
# ============================================================
_case_parse_upgrade_local_args() {
    echo "=== Test: parse_upgrade_local_args ==="
    (
        load_modules

        parse_upgrade_local_args --kubernetes-version 1.33.2 --first-control-plane --skip-drain
        _assert_eq "UPGRADE_TARGET_VERSION parsed" "1.33.2" "$UPGRADE_TARGET_VERSION"
        _assert_eq "UPGRADE_FIRST_CONTROL_PLANE parsed" "true" "$UPGRADE_FIRST_CONTROL_PLANE"
        _assert_eq "UPGRADE_SKIP_DRAIN parsed" "true" "$UPGRADE_SKIP_DRAIN"
    )
}

# ============================================================
# Test: upgrade --kubernetes-version format validation
# ============================================================
_case_upgrade_version_format() {
    echo "=== Test: upgrade --kubernetes-version format validation ==="
    (
        load_modules

        # MAJOR.MINOR should be rejected (must be MAJOR.MINOR.PATCH)
        local exit_code=0
        (parse_upgrade_local_args --kubernetes-version 1.33) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "MAJOR.MINOR rejected" "0" "$exit_code"

        # MAJOR.MINOR.PATCH should be accepted
        exit_code=0
        (parse_upgrade_local_args --kubernetes-version 1.33.2) >/dev/null 2>&1 || exit_code=$?
        _assert_eq "MAJOR.MINOR.PATCH accepted" "0" "$exit_code"

        # Missing --kubernetes-version should be rejected
        exit_code=0
        (parse_upgrade_local_args --first-control-plane) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "missing --kubernetes-version rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: _k8s_minor_version extraction
# ============================================================
_case_k8s_minor_version() {
    echo "=== Test: _k8s_minor_version extraction ==="
    (
        load_modules

        _assert_eq "_k8s_minor_version 1.33.2" "1.33" "$(_k8s_minor_version "1.33.2")"
        _assert_eq "_k8s_minor_version 1.28.0" "1.28" "$(_k8s_minor_version "1.28.0")"
        _assert_eq "_k8s_minor_version 2.0.1" "2.0" "$(_k8s_minor_version "2.0.1")"
    )
}

# ============================================================
# Test: _validate_upgrade_version constraints
# ============================================================
_case_validate_upgrade_version() {
    echo "=== Test: _validate_upgrade_version constraints ==="
    (
        load_modules

        # +1 minor should be OK
        local exit_code=0
        (_validate_upgrade_version "1.32.0" "1.33.2") >/dev/null 2>&1 || exit_code=$?
        _assert_eq "+1 minor allowed" "0" "$exit_code"

        # Same minor, higher patch should be OK
        exit_code=0
        (_validate_upgrade_version "1.32.0" "1.32.5") >/dev/null 2>&1 || exit_code=$?
        _assert_eq "patch upgrade allowed" "0" "$exit_code"

        # +2 minor should be rejected
        exit_code=0
        (_validate_upgrade_version "1.31.0" "1.33.0") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "+2 minor rejected" "0" "$exit_code"

        # Downgrade should be rejected
        exit_code=0
        (_validate_upgrade_version "1.33.0" "1.32.0") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "downgrade rejected" "0" "$exit_code"

        # Same version should be rejected
        exit_code=0
        (_validate_upgrade_version "1.33.2" "1.33.2") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "same version rejected" "0" "$exit_code"

        # Patch downgrade should be rejected
        exit_code=0
        (_validate_upgrade_version "1.33.5" "1.33.2") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "patch downgrade rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: _detect_node_role
# ============================================================
_case_detect_node_role() {
    echo "=== Test: _detect_node_role ==="
    (
        load_modules

        # Without kube-apiserver manifest -> worker
        local role
        role=$(_detect_node_role)
        _assert_eq "no manifest = worker" "worker" "$role"

        # With UPGRADE_FIRST_CONTROL_PLANE=false and no manifest -> worker
        UPGRADE_FIRST_CONTROL_PLANE=true
        role=$(_detect_node_role)
        _assert_eq "no manifest + first-cp flag = still worker" "worker" "$role"
    )
}

# ============================================================
# Test: upgrade --help exits 0
# ============================================================
_case_upgrade_help_exit() {
    echo "=== Test: upgrade --help exits 0 ==="
    _assert_exit_code "setup-k8s.sh upgrade --help exits 0" 0 bash "$PROJECT_ROOT/setup-k8s.sh" upgrade --help
}

# ============================================================
# Test: _validate_upgrade_version format validation
# ============================================================
_case_validate_upgrade_version_format() {
    echo "=== Test: _validate_upgrade_version format validation ==="
    (
        load_modules

        # Invalid format should be rejected
        local exit_code=0
        (_validate_upgrade_version "1.32" "1.33.0") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "MAJOR.MINOR current rejected" "0" "$exit_code"

        exit_code=0
        (_validate_upgrade_version "1.32.0" "latest") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "non-numeric target rejected" "0" "$exit_code"

        exit_code=0
        (_validate_upgrade_version "" "1.33.0") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "empty current rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: UPGRADE_NO_ROLLBACK default and --no-rollback parsing
# ============================================================
_case_upgrade_rollback_flag() {
    echo "=== Test: --no-rollback flag ==="
    (
        load_modules

        # Default value
        _assert_eq "UPGRADE_NO_ROLLBACK default" "false" "$UPGRADE_NO_ROLLBACK"

        # Parse --no-rollback in local mode
        UPGRADE_NO_ROLLBACK=false
        parse_upgrade_local_args --kubernetes-version 1.33.2 --no-rollback
        _assert_eq "--no-rollback parsed (local)" "true" "$UPGRADE_NO_ROLLBACK"

        # Parse --no-rollback in deploy mode
        UPGRADE_NO_ROLLBACK=false
        parse_upgrade_deploy_args --control-planes 10.0.0.1 --kubernetes-version 1.33.2 --no-rollback
        _assert_eq "--no-rollback parsed (deploy)" "true" "$UPGRADE_NO_ROLLBACK"
    )
}

# ============================================================
# Test: auto-step-upgrade default
# ============================================================
_case_auto_step_upgrade_default() {
    echo "=== Test: auto-step-upgrade default ==="
    (
        load_modules
        _assert_eq "UPGRADE_AUTO_STEP default" "false" "$UPGRADE_AUTO_STEP"
    )
}

# ============================================================
# Test: parse --auto-step-upgrade
# ============================================================
_case_parse_auto_step_upgrade() {
    echo "=== Test: parse --auto-step-upgrade ==="
    (
        load_modules
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        _require_value() { [ "$1" -ge 2 ] || { echo "missing value for $2" >&2; exit 1; }; }
        _parse_distro_arg() { :; }

        parse_upgrade_local_args --kubernetes-version 1.33.2 --auto-step-upgrade
        _assert_eq "UPGRADE_AUTO_STEP parsed (local)" "true" "$UPGRADE_AUTO_STEP"
    )
}

@test "UPGRADE_* variable defaults" {
    _case_upgrade_variables_defaults
}

@test "parse_upgrade_local_args" {
    _case_parse_upgrade_local_args
}

@test "upgrade --kubernetes-version format validation" {
    _case_upgrade_version_format
}

@test "_k8s_minor_version extraction" {
    _case_k8s_minor_version
}

@test "_validate_upgrade_version constraints" {
    _case_validate_upgrade_version
}

@test "_detect_node_role" {
    _case_detect_node_role
}

@test "upgrade --help exits 0" {
    _case_upgrade_help_exit
}

@test "_validate_upgrade_version format validation" {
    _case_validate_upgrade_version_format
}

@test "--no-rollback flag" {
    _case_upgrade_rollback_flag
}

@test "auto-step-upgrade default" {
    _case_auto_step_upgrade_default
}

@test "parse --auto-step-upgrade" {
    _case_parse_auto_step_upgrade
}

# --- node resolution, verification, kubelet restart ---

_fake_nodes() {
    NODES="$1"
    _deploy_ssh() {
        case "$3" in
            *"get nodes -o jsonpath"*) [ -n "$NODES" ] && printf '%s\n' "$NODES" ;;
            hostname) echo "${REMOTE_HOSTNAME:-}" ;;
        esac
    }
    sleep() { :; }
}

@test "_get_node_name: a unique address match wins" {
    load_modules; quiet_logs
    _fake_nodes 'cp1 10.0.0.1 cp1
w1 10.0.0.2 w1'
    [ "$(_get_node_name root 10.0.0.1 10.0.0.2)" = w1 ]
}

@test "_get_node_name: nodes sharing an address are told apart by hostname" {
    load_modules; quiet_logs
    _fake_nodes 'cp1 10.0.2.15 cp1
w1 10.0.2.15 w1'
    _DEPLOY_ALL_NODES="10.0.2.15"
    REMOTE_HOSTNAME=W1
    [ "$(_get_node_name root 10.0.0.1 10.0.2.15)" = w1 ]
}

@test "_get_node_name: unknown node and unreachable API are different failures" {
    load_modules; quiet_logs
    _fake_nodes 'cp1 10.0.0.1 cp1'
    REMOTE_HOSTNAME=other
    run _get_node_name root 10.0.0.1 10.0.0.9
    [ "$status" -eq 1 ]
    _fake_nodes ''
    run _get_node_name root 10.0.0.1 10.0.0.9
    [ "$status" -eq 2 ]
}

@test "the cluster must report the upgraded kubelet and API server versions" {
    load_modules; quiet_logs
    sleep() { :; }
    _deploy_ssh() {
        case "$3" in
            *"get node"*kubeletVersion*) echo "$KUBELET_V" ;;
            *"version -o json"*) printf '{\n "clientVersion": {\n  "gitVersion": "v1.37.2"\n },\n "serverVersion": {\n  "gitVersion": "%s"\n }\n}\n' "$SERVER_V" ;;
        esac
    }
    KUBELET_V=v1.37.2 SERVER_V=v1.37.2
    _upgrade_verify_node_version root cp1 w1 1.37.2
    _upgrade_verify_api_version root cp1 1.37.2
    KUBELET_V=v1.36.6 SERVER_V=v1.36.6
    run _upgrade_verify_node_version root cp1 w1 1.37.2
    [ "$status" -ne 0 ]
    run _upgrade_verify_api_version root cp1 1.37.2
    [ "$status" -ne 0 ]
}

@test "a failing uncordon is retried and then reported" {
    load_modules; quiet_logs
    sleep() { :; }
    TRIES="$BATS_TEST_TMPDIR/tries"; : > "$TRIES"
    _deploy_ssh() { echo x >> "$TRIES"; [ "$(wc -l < "$TRIES")" -ge "${OK_AT:-99}" ]; }
    OK_AT=3 _upgrade_uncordon_node root cp1 w1
    : > "$TRIES"
    run _upgrade_uncordon_node root cp1 w1
    [ "$status" -ne 0 ]
    [ "$(wc -l < "$TRIES")" -eq 5 ]
}

@test "node upgrade fails when kubelet does not stay active or versions differ" {
    load_modules; quiet_logs
    sleep() { :; }
    _service_reload() { :; }
    _service_restart() { :; }
    _service_is_active() { [ "${KUBELET_UP:-true}" = true ]; }
    run _upgrade_restart_kubelet
    [ "$status" -eq 0 ]
    KUBELET_UP=false
    run _upgrade_restart_kubelet
    [ "$status" -ne 0 ]
    cat > "$FAKE_BIN/kubeadm" <<'FAKE'
#!/bin/sh
echo v1.37.2
FAKE
    cat > "$FAKE_BIN/kubelet" <<'FAKE'
#!/bin/sh
echo "Kubernetes v1.36.6"
FAKE
    chmod +x "$FAKE_BIN/kubeadm" "$FAKE_BIN/kubelet"
    run _upgrade_verify_local_versions 1.37.2
    [ "$status" -ne 0 ]
}

@test "kubeadm upgrade apply skips the node-readiness checks only while nodes are NotReady" {
    load_modules; quiet_logs
    _detect_node_role() { echo first-control-plane; }
    _get_current_k8s_version() { echo 1.36.6; }
    k8s_upgrade_kubeadm() { :; }
    k8s_upgrade_node() { :; }
    _upgrade_restart_kubelet() { :; }
    _upgrade_verify_local_versions() { :; }
    show_versions() { :; }
    _detect_init_system() { echo systemd; }
    crio_in_use() { return 1; }
    fake_cmd kubeadm
    UPGRADE_TARGET_VERSION=1.37.2
    fake_cmd kubectl 0 "cp1 NotReady control-plane 1m v1.36.6"
    upgrade_node_local
    fake_calls | grep -qx 'kubeadm upgrade apply v1.37.2 --yes --ignore-preflight-errors=ControlPlaneNodesReady,CreateJob'
    : > "$FAKE_LOG"
    fake_cmd kubectl 0 "cp1 Ready control-plane 1m v1.36.6"
    upgrade_node_local
    fake_calls | grep -qx 'kubeadm upgrade apply v1.37.2 --yes'
}

@test "node upgrade and rollback move CRI-O to the Kubernetes minor" {
    load_modules; quiet_logs
    CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
    _detect_node_role() { echo worker; }
    _get_current_k8s_version() { echo 1.36.6; }
    k8s_upgrade_kubeadm() { echo "kubeadm $1" >> "$CALLS"; }
    k8s_upgrade_node() { echo "node $1" >> "$CALLS"; }
    crio_in_use() { return 0; }
    crio_set_minor() { echo "crio $1" >> "$CALLS"; }
    _upgrade_restart_kubelet() { echo restart >> "$CALLS"; }
    _upgrade_verify_local_versions() { :; }
    show_versions() { :; }
    fake_cmd kubeadm
    UPGRADE_TARGET_VERSION=1.37.2
    upgrade_node_local
    [ "$(cat "$CALLS")" = "kubeadm 1.37.2
node 1.37.2
crio 1.37
restart" ]
    : > "$CALLS"
    _get_current_k8s_version() { echo 1.37.2; }
    UPGRADE_ROLLBACK_VERSION=1.36.6
    rollback_node_local
    grep -qx 'crio 1.36' "$CALLS"
}

@test "upgrade accepts prerelease targets and orders them before the release" {
    load_modules; quiet_logs
    _parse_upgrade_common_arg 2 --kubernetes-version 1.38.0-beta.0
    [ "$UPGRADE_TARGET_VERSION" = 1.38.0-beta.0 ]
    _validate_upgrade_version 1.37.2 1.38.0-beta.0
    _validate_upgrade_version 1.38.0-beta.0 1.38.0
    _validate_upgrade_version 1.38.0-alpha.3 1.38.0-rc.0
    run _validate_upgrade_version 1.38.0 1.38.0-rc.1
    [ "$status" -ne 0 ]
    run _validate_upgrade_version 1.38.0-beta.0 1.38.0-beta.0
    [ "$status" -ne 0 ]
}
