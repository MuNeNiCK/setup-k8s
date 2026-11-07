#!/usr/bin/env bats
# Ported from test/unit/test_renew.sh

setup() {
    load '../helpers/common'
}

# File-local module loaders
_load_renew_test_modules() {
    load_modules
}

_load_renew_cert_test_modules() {
    load_modules
}

# ============================================================
# Test: RENEW_* variable defaults
# ============================================================
_case_renew_variables_defaults() {
    echo "=== Test: RENEW_* variable defaults ==="
    (
        load_modules
        _assert_eq "RENEW_CERTS default" "all" "$RENEW_CERTS"
        _assert_eq "RENEW_CHECK_ONLY default" "false" "$RENEW_CHECK_ONLY"
        _assert_eq "RENEW_PASSTHROUGH_ARGS default" "" "$RENEW_PASSTHROUGH_ARGS"
    )
}

# ============================================================
# Test: parse_renew_local_args
# ============================================================
_case_parse_renew_local_args() {
    echo "=== Test: parse_renew_local_args ==="
    (
        _load_renew_test_modules

        parse_renew_local_args --certs apiserver,etcd-server --check-only
        _assert_eq "RENEW_CERTS parsed" "apiserver,etcd-server" "$RENEW_CERTS"
        _assert_eq "RENEW_CHECK_ONLY parsed" "true" "$RENEW_CHECK_ONLY"
    )
}

# ============================================================
# Test: parse_renew_deploy_args
# ============================================================
_case_parse_renew_deploy_args() {
    echo "=== Test: parse_renew_deploy_args ==="
    (
        _load_renew_test_modules

        parse_renew_deploy_args --control-planes 10.0.0.1,10.0.0.2 --certs apiserver --check-only --ssh-port 2222
        _assert_eq "DEPLOY_CONTROL_PLANES parsed" "10.0.0.1,10.0.0.2" "$DEPLOY_CONTROL_PLANES"
        _assert_eq "RENEW_CERTS parsed" "apiserver" "$RENEW_CERTS"
        _assert_eq "RENEW_CHECK_ONLY parsed" "true" "$RENEW_CHECK_ONLY"
        _assert_eq "DEPLOY_SSH_PORT parsed" "2222" "$DEPLOY_SSH_PORT"

        # Verify passthrough args contain --certs and --check-only
        local has_certs="false" has_check="false"
        if echo "$RENEW_PASSTHROUGH_ARGS" | grep -q -- '--certs'; then has_certs="true"; fi
        if echo "$RENEW_PASSTHROUGH_ARGS" | grep -q -- '--check-only'; then has_check="true"; fi
        _assert_eq "passthrough has --certs" "true" "$has_certs"
        _assert_eq "passthrough has --check-only" "true" "$has_check"
    )
}

# ============================================================
# Test: validate_renew_deploy_args requires --control-planes
# ============================================================
_case_validate_renew_deploy_args_required() {
    echo "=== Test: validate_renew_deploy_args requires --control-planes ==="
    (
        _load_renew_test_modules

        # Missing --control-planes should fail
        local exit_code=0
        (validate_renew_deploy_args) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "missing --control-planes rejected" "0" "$exit_code"

        # With valid --control-planes should pass
        DEPLOY_CONTROL_PLANES="10.0.0.1"
        exit_code=0
        (validate_renew_deploy_args) >/dev/null 2>&1 || exit_code=$?
        _assert_eq "valid --control-planes accepted" "0" "$exit_code"
    )
}

# ============================================================
# Test: renew --help exits 0
# ============================================================
_case_renew_help_exit() {
    echo "=== Test: renew --help exits 0 ==="
    _assert_exit_code "setup-k8s.sh renew --help exits 0" 0 bash "$PROJECT_ROOT/setup-k8s.sh" renew --help
}

# ============================================================
# Test: help text contains 'renew'
# ============================================================
_case_help_contains_renew() {
    echo "=== Test: help text contains renew ==="
    (
        local help_out
        help_out=$(bash "$PROJECT_ROOT/setup-k8s.sh" --help 2>&1)
        local has_renew="false"
        if echo "$help_out" | grep -q 'renew'; then has_renew="true"; fi
        _assert_eq "help contains renew" "true" "$has_renew"
    )
}

# ============================================================
# Test: _validate_cert_names
# ============================================================
_case_validate_cert_names() {
    echo "=== Test: _validate_cert_names ==="
    (
        _load_renew_cert_test_modules

        # "all" should pass
        RENEW_CERTS="all"
        _validate_cert_names
        _assert_eq "all passes" "all" "$RENEW_CERTS"

        # Valid names should pass
        RENEW_CERTS="apiserver,etcd-server,admin.conf"
        local exit_code=0
        (_validate_cert_names) >/dev/null 2>&1 || exit_code=$?
        _assert_eq "valid cert names pass" "0" "$exit_code"

        # Invalid name should fail
        RENEW_CERTS="apiserver,bogus-cert"
        exit_code=0
        (_validate_cert_names) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "invalid cert name rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: parse_renew_local_args rejects unknown option
# ============================================================
_case_parse_renew_unknown_option() {
    echo "=== Test: parse_renew_local_args unknown option ==="
    (
        _load_renew_test_modules

        local exit_code=0
        (parse_renew_local_args --bogus-flag) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "unknown option rejected" "0" "$exit_code"
    )
}

@test "RENEW_* variable defaults" {
    _case_renew_variables_defaults
}

@test "parse_renew_local_args" {
    _case_parse_renew_local_args
}

@test "parse_renew_deploy_args" {
    _case_parse_renew_deploy_args
}

@test "validate_renew_deploy_args requires --control-planes" {
    _case_validate_renew_deploy_args_required
}

@test "renew --help exits 0" {
    _case_renew_help_exit
}

@test "help text contains renew" {
    _case_help_contains_renew
}

@test "_validate_cert_names" {
    _case_validate_cert_names
}

@test "parse_renew_local_args unknown option" {
    _case_parse_renew_unknown_option
}

# --- renewal verification ---
# Fake kubeadm/crictl/kubectl. kubeadm reports the expiry from
# $STATE/expiry (renew rewrites it to $RENEWED_DATE); crictl reports the
# container ID from $STATE/cid-<name> and "stop" gives it a new ID unless
# NO_RESTART names the component.
_fake_control_plane() {
    STATE="$BATS_TEST_TMPDIR/cp"
    mkdir -p "$STATE"
    echo "2027-01-01T00:00:00Z" > "$STATE/expiry"
    RENEWED_DATE="${RENEWED_DATE:-2027-11-07T00:00:00Z}"
    for c in kube-apiserver kube-controller-manager kube-scheduler etcd; do echo "old-$c" > "$STATE/cid-$c"; done
    cat > "$FAKE_BIN/kubeadm" <<FAKE
#!/bin/sh
case "\$*" in
    "certs check-expiration -o json")
        d=\$(cat "$STATE/expiry")
        printf '{\n "certificates": [\n  {\n   "name": "admin.conf",\n   "expirationDate": "%s"\n  },\n  {\n   "name": "apiserver",\n   "expirationDate": "%s"\n  }\n ],\n "certificateAuthorities": [\n  {\n   "name": "ca",\n   "expirationDate": "2035-01-01T00:00:00Z"\n  }\n ]\n}\n' "\$d" "\$d" ;;
    "certs check-expiration") echo "CERTIFICATE EXPIRES" ;;
    "certs renew"*) echo "$RENEWED_DATE" > "$STATE/expiry" ;;
esac
FAKE
    cat > "$FAKE_BIN/crictl" <<FAKE
#!/bin/sh
case "\$1" in
    ps) for a in "\$@"; do case "\$a" in --name=*) n=\${a#--name=^}; n=\${n%\\\$} ;; esac; done; cat "$STATE/cid-\$n" ;;
    stop) for c in kube-apiserver kube-controller-manager kube-scheduler etcd; do
              [ "\$(cat "$STATE/cid-\$c")" = "\$2" ] && [ "\${NO_RESTART:-}" != "\$c" ] && echo "new-\$c" > "$STATE/cid-\$c"; done ;;
esac
exit 0
FAKE
    chmod +x "$FAKE_BIN/kubeadm" "$FAKE_BIN/crictl"
    fake_cmd kubectl 0
    sleep() { :; }
}

@test "renewal restarts the components and verifies the new expiry" {
    load_modules; quiet_logs; _fake_control_plane
    _RENEW_APISERVER_MANIFEST="$BATS_TEST_TMPDIR/kube-apiserver.yaml"
    touch "$_RENEW_APISERVER_MANIFEST"
    RENEW_CERTS=all RENEW_CHECK_ONLY=false
    run renew_certs_local
    [ "$status" -eq 0 ]
    [ "$(cat "$STATE/cid-kube-apiserver")" = new-kube-apiserver ]
    [ "$(cat "$STATE/cid-etcd")" = new-etcd ]
}

@test "renewal fails when crictl is missing" {
    load_modules; quiet_logs; _fake_control_plane
    rm -f "$FAKE_BIN/crictl"
    command() { if [ "$1" = -v ] && [ "$2" = crictl ]; then return 1; fi; builtin command "$@"; }
    RENEW_CERTS=all
    run _restart_control_plane_components
    [ "$status" -ne 0 ]
}

@test "renewal fails when a component does not restart" {
    load_modules; quiet_logs; _fake_control_plane
    RENEW_CERTS=apiserver
    NO_RESTART=kube-scheduler
    export NO_RESTART
    run _restart_control_plane_components
    [ "$status" -ne 0 ]
}

@test "renewal fails when a certificate still has the old expiry" {
    load_modules; quiet_logs
    RENEWED_DATE="2027-01-01T00:00:00Z" _fake_control_plane
    RENEW_CERTS=apiserver
    before=$(_renew_expiry_dates)
    kubeadm certs renew apiserver
    run _renew_verify_expiry "$before" "$(_renew_expiry_dates)"
    [ "$status" -ne 0 ]
    # A later expiry passes; certificate authorities are not listed
    echo "2027-11-07T00:00:00Z" > "$STATE/expiry"
    run _renew_verify_expiry "$before" "$(_renew_expiry_dates)"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$before" | awk '{print $1}' | tr '\n' ' ')" = "admin.conf apiserver " ]
}
