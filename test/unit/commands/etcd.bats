#!/usr/bin/env bats
# Ported from test/unit/test_etcd.sh

setup() {
    load '../helpers/common'
}

# File-local module loader (avoids repeating 11-line source block in every test)
_load_etcd_test_modules() {
    load_modules
}

# ============================================================
# Test: ETCD_* variable defaults
# ============================================================
_case_etcd_variables_defaults() {
    echo "=== Test: ETCD_* variable defaults ==="
    (
        load_modules
        _assert_eq "ETCD_SNAPSHOT_PATH default" "" "$ETCD_SNAPSHOT_PATH"
        _assert_eq "ETCD_CONTROL_PLANES default" "" "$ETCD_CONTROL_PLANES"
    )
}

# ============================================================
# Test: parse_backup_local_args
# ============================================================
_case_parse_backup_local_args() {
    echo "=== Test: parse_backup_local_args ==="
    (
        _load_etcd_test_modules

        # With explicit snapshot path
        parse_backup_local_args --snapshot-path /tmp/test-snapshot.db
        _assert_eq "ETCD_SNAPSHOT_PATH parsed" "/tmp/test-snapshot.db" "$ETCD_SNAPSHOT_PATH"
    )
}

# ============================================================
# Test: parse_backup_local_args default snapshot path
# ============================================================
_case_parse_backup_local_args_default_path() {
    echo "=== Test: parse_backup_local_args default path ==="
    (
        _load_etcd_test_modules

        # Without snapshot path, should get auto-generated default
        parse_backup_local_args
        local has_prefix="false"
        if [[ "$ETCD_SNAPSHOT_PATH" == /var/lib/etcd-backup/snapshot-*.db ]]; then has_prefix="true"; fi
        _assert_eq "backup default path has expected prefix" "true" "$has_prefix"
    )
}

# ============================================================
# Test: parse_restore_local_args requires --snapshot-path
# ============================================================
_case_parse_restore_local_args_required() {
    echo "=== Test: parse_restore_local_args requires --snapshot-path ==="
    (
        _load_etcd_test_modules

        local exit_code=0
        (parse_restore_local_args) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "missing --snapshot-path rejected" "0" "$exit_code"

        exit_code=0
        (parse_restore_local_args --snapshot-path /tmp/snap.db) >/dev/null 2>&1 || exit_code=$?
        _assert_eq "with --snapshot-path accepted" "0" "$exit_code"
    )
}

# ============================================================
# Test: parse_backup_remote_args
# ============================================================
_case_parse_backup_remote_args() {
    echo "=== Test: parse_backup_remote_args ==="
    (
        _load_etcd_test_modules

        parse_backup_remote_args --control-planes 10.0.0.1 --snapshot-path /tmp/snap.db --ssh-port 2222
        _assert_eq "ETCD_CONTROL_PLANES parsed" "10.0.0.1" "$ETCD_CONTROL_PLANES"
        _assert_eq "ETCD_SNAPSHOT_PATH parsed" "/tmp/snap.db" "$ETCD_SNAPSHOT_PATH"
        _assert_eq "DEPLOY_SSH_PORT parsed" "2222" "$DEPLOY_SSH_PORT"
    )
}

# ============================================================
# Test: parse_restore_remote_args
# ============================================================
_case_parse_restore_remote_args() {
    echo "=== Test: parse_restore_remote_args ==="
    (
        _load_etcd_test_modules

        parse_restore_remote_args --control-planes admin@10.0.0.1 --snapshot-path /tmp/snap.db --ssh-key /tmp/id_rsa
        _assert_eq "ETCD_CONTROL_PLANES parsed" "admin@10.0.0.1" "$ETCD_CONTROL_PLANES"
        _assert_eq "ETCD_SNAPSHOT_PATH parsed" "/tmp/snap.db" "$ETCD_SNAPSHOT_PATH"
        _assert_eq "DEPLOY_SSH_KEY parsed" "/tmp/id_rsa" "$DEPLOY_SSH_KEY"
    )
}

# ============================================================
# Test: validate_backup_remote_args requires --control-planes
# ============================================================
_case_validate_backup_remote_args() {
    echo "=== Test: validate_backup_remote_args ==="
    (
        _load_etcd_test_modules

        # Missing --control-planes should fail
        local exit_code=0
        (validate_backup_remote_args) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "missing --control-planes rejected" "0" "$exit_code"

        # With valid --control-planes should pass
        ETCD_CONTROL_PLANES="10.0.0.1"
        exit_code=0
        (validate_backup_remote_args) >/dev/null 2>&1 || exit_code=$?
        _assert_eq "valid --control-planes accepted" "0" "$exit_code"
    )
}

# ============================================================
# Test: backup/restore unknown option
# ============================================================
_case_backup_restore_unknown_option() {
    echo "=== Test: backup/restore unknown option ==="
    (
        _load_etcd_test_modules

        local exit_code=0
        (parse_backup_local_args --bogus-flag) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "backup unknown option rejected" "0" "$exit_code"

        exit_code=0
        (parse_restore_local_args --bogus-flag) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "restore unknown option rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: backup --help exits 0
# ============================================================
_case_backup_help_exit() {
    echo "=== Test: backup --help exits 0 ==="
    _assert_exit_code "setup-k8s.sh backup --help exits 0" 0 bash "$PROJECT_ROOT/setup-k8s.sh" backup --help
}

# ============================================================
# Test: restore --help exits 0
# ============================================================
_case_restore_help_exit() {
    echo "=== Test: restore --help exits 0 ==="
    _assert_exit_code "setup-k8s.sh restore --help exits 0" 0 bash "$PROJECT_ROOT/setup-k8s.sh" restore --help
}

# ============================================================
# Test: help text contains 'backup' and 'restore'
# ============================================================
_case_help_contains_backup_restore() {
    echo "=== Test: help text contains backup/restore ==="
    (
        local help_out
        help_out=$(bash "$PROJECT_ROOT/setup-k8s.sh" --help 2>&1)
        local has_backup="false"
        if echo "$help_out" | grep -q 'backup'; then has_backup="true"; fi
        _assert_eq "help contains backup" "true" "$has_backup"

        local has_restore="false"
        if echo "$help_out" | grep -q 'restore'; then has_restore="true"; fi
        _assert_eq "help contains restore" "true" "$has_restore"
    )
}

# ============================================================
# Test: etcd.sh core functions defined
# ============================================================
_case_etcd_functions_defined() {
    echo "=== Test: etcd.sh core functions defined ==="
    (
        load_modules
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        _audit_log() { :; }
        _require_value() { :; }
        _parse_common_ssh_args() { :; }
        _SSH_SHIFT=0

        local has_backup="false"
        type backup_etcd_local >/dev/null 2>&1 && has_backup="true"
        _assert_eq "backup_etcd_local defined" "true" "$has_backup"

        local has_restore="false"
        type restore_etcd_local >/dev/null 2>&1 && has_restore="true"
        _assert_eq "restore_etcd_local defined" "true" "$has_restore"

        local has_find_container="false"
        type _find_etcd_container >/dev/null 2>&1 && has_find_container="true"
        _assert_eq "_find_etcd_container defined" "true" "$has_find_container"

        local has_etcdctl="false"
        type _etcdctl_exec >/dev/null 2>&1 && has_etcdctl="true"
        _assert_eq "_etcdctl_exec defined" "true" "$has_etcdctl"

        local has_extract="false"
        type _extract_etcd_binaries >/dev/null 2>&1 && has_extract="true"
        _assert_eq "_extract_etcd_binaries defined" "true" "$has_extract"
    )
}

# ============================================================
# Test: etcd backup path variables (deep)
# ============================================================
_case_etcd_backup_path_variables() {
    echo "=== Test: etcd backup path variables ==="
    (
        load_modules
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        _audit_log() { :; }
        _require_value() { :; }
        _parse_common_ssh_args() { :; }
        _SSH_SHIFT=0

        # Verify TLS cert paths
        _assert_eq "etcd cert path" "/etc/kubernetes/pki/etcd/server.crt" "$_ETCD_CERT"
        _assert_eq "etcd key path" "/etc/kubernetes/pki/etcd/server.key" "$_ETCD_KEY"
        _assert_eq "etcd CA path" "/etc/kubernetes/pki/etcd/ca.crt" "$_ETCD_CACERT"
        _assert_eq "etcd manifest path" "/etc/kubernetes/manifests/etcd.yaml" "$_ETCD_MANIFEST_PATH"
    )
}

# ============================================================
# Test: _find_etcd_container error when crictl not found (deep)
# ============================================================
_case_find_etcd_container_error() {
    echo "=== Test: _find_etcd_container error when crictl not found ==="
    (
        load_modules
        local captured_error=""
        log_error() { captured_error="$*"; }
        log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        _audit_log() { :; }
        _require_value() { :; }
        _parse_common_ssh_args() { :; }
        _SSH_SHIFT=0

        # Override crictl to simulate not found
        crictl() { return 1; }

        local rc=0
        _find_etcd_container 2>/dev/null || rc=$?
        _assert_ne "find_etcd_container fails" "0" "$rc"

        local has_msg="false"
        echo "$captured_error" | grep -q "etcd container not found" && has_msg="true"
        _assert_eq "error message mentions etcd container" "true" "$has_msg"
    )
}

# ============================================================
# Test: _find_etcd_container falls back to inspecting running containers
# ============================================================
_case_find_etcd_container_inspect_fallback() {
    echo "=== Test: _find_etcd_container inspect fallback ==="
    (
        load_modules
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        _audit_log() { :; }
        _require_value() { :; }
        _parse_common_ssh_args() { :; }
        _SSH_SHIFT=0

        crictl() {
            case "$*" in
                "ps --name=etcd --state=running -q")
                    return 0
                    ;;
                "ps --state=running -q")
                    printf '%s\n' "cid-apiserver" "cid-etcd"
                    ;;
                "inspect cid-apiserver")
                    printf '%s\n' '{"info":{"config":{"metadata":{"name":"kube-apiserver"}}}}'
                    ;;
                "inspect cid-etcd")
                    printf '%s\n' '{"status":{"labels":{"io.kubernetes.container.name":"etcd"}}}'
                    ;;
                *)
                    return 1
                    ;;
            esac
        }

        local cid
        cid=$(_find_etcd_container)
        _assert_eq "find_etcd_container inspect fallback" "cid-etcd" "$cid"
    )
}

# ============================================================
# Test: _resolve_etcd_image_ref prefers exportable image names over digests
# ============================================================
_case_resolve_etcd_image_ref_prefers_name() {
    echo "=== Test: _resolve_etcd_image_ref prefers image name ==="
    (
        load_modules
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        _audit_log() { :; }
        _require_value() { :; }
        _parse_common_ssh_args() { :; }
        _SSH_SHIFT=0

        crictl() {
            case "$*" in
                "inspect cid-etcd")
                    printf '%s\n' '{"status":{"imageRef":"sha256:abc","image":{"image":"registry.k8s.io/etcd:3.6.6-0"}}}'
                    ;;
                *)
                    return 1
                    ;;
            esac
        }
        ctr() { return 1; }

        local image_ref
        image_ref=$(_resolve_etcd_image_ref cid-etcd)
        _assert_eq "resolve_etcd_image_ref prefers image name" "registry.k8s.io/etcd:3.6.6-0" "$image_ref"
    )
}

_case_resolve_etcd_image_ref_ctr_fallback() {
    echo "=== Test: _resolve_etcd_image_ref ctr fallback ==="
    (
        load_modules
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        _audit_log() { :; }
        _require_value() { :; }
        _parse_common_ssh_args() { :; }
        _SSH_SHIFT=0

        crictl() {
            case "$*" in
                "inspect cid-etcd")
                    printf '%s\n' '{"status":{"imageRef":"sha256:abc","image":"sha256:def"}}'
                    ;;
                *)
                    return 1
                    ;;
            esac
        }
        ctr() {
            case "$*" in
                "-n k8s.io containers info cid-etcd")
                    printf '%s\n' '{"image":"registry.k8s.io/etcd:3.6.6-0"}'
                    ;;
                *)
                    return 1
                    ;;
            esac
        }

        local image_ref
        image_ref=$(_resolve_etcd_image_ref cid-etcd)
        _assert_eq "resolve_etcd_image_ref ctr fallback" "registry.k8s.io/etcd:3.6.6-0" "$image_ref"
    )
}

@test "ETCD_* variable defaults" {
    _case_etcd_variables_defaults
}

@test "parse_backup_local_args" {
    _case_parse_backup_local_args
}

@test "parse_backup_local_args default path" {
    _case_parse_backup_local_args_default_path
}

@test "parse_restore_local_args requires --snapshot-path" {
    _case_parse_restore_local_args_required
}

@test "parse_backup_remote_args" {
    _case_parse_backup_remote_args
}

@test "parse_restore_remote_args" {
    _case_parse_restore_remote_args
}

@test "validate_backup_remote_args" {
    _case_validate_backup_remote_args
}

@test "backup/restore unknown option" {
    _case_backup_restore_unknown_option
}

@test "backup --help exits 0" {
    _case_backup_help_exit
}

@test "restore --help exits 0" {
    _case_restore_help_exit
}

@test "help text contains backup/restore" {
    _case_help_contains_backup_restore
}

@test "etcd.sh core functions defined" {
    _case_etcd_functions_defined
}

@test "etcd backup path variables" {
    _case_etcd_backup_path_variables
}

@test "_find_etcd_container error when crictl not found" {
    _case_find_etcd_container_error
}

@test "_find_etcd_container inspect fallback" {
    _case_find_etcd_container_inspect_fallback
}

@test "_resolve_etcd_image_ref prefers image name" {
    _case_resolve_etcd_image_ref_prefers_name
}

@test "_resolve_etcd_image_ref ctr fallback" {
    _case_resolve_etcd_image_ref_ctr_fallback
}
