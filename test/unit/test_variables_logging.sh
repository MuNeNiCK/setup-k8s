#!/bin/sh
# Unit tests for variables.sh and logging.sh

# ============================================================
# Test: variables.sh defaults
# ============================================================
test_variables_defaults() {
    echo "=== Test: variables.sh defaults ==="
    (
        source "$PROJECT_ROOT/lib/variables.sh"
        _assert_eq "LOG_LEVEL default" "1" "$LOG_LEVEL"
        _assert_eq "DRY_RUN default" "false" "$DRY_RUN"
        _assert_eq "ACTION default" "" "$ACTION"
        _assert_eq "CRI default" "containerd" "$CRI"
        _assert_eq "PROXY_MODE default" "iptables" "$PROXY_MODE"
        _assert_eq "FORCE default" "false" "$FORCE"
        _assert_eq "ENABLE_COMPLETION default" "true" "$ENABLE_COMPLETION"
        _assert_eq "INSTALL_HELM default" "false" "$INSTALL_HELM"
        _assert_eq "INSTALL_KUSTOMIZE default" "false" "$INSTALL_KUSTOMIZE"
        _assert_eq "JOIN_AS_CONTROL_PLANE default" "false" "$JOIN_AS_CONTROL_PLANE"
        _assert_eq "HA_ENABLED default" "false" "$HA_ENABLED"
        _assert_eq "KUBEADM_POD_CIDR default" "" "$KUBEADM_POD_CIDR"
        _assert_eq "KUBEADM_SERVICE_CIDR default" "" "$KUBEADM_SERVICE_CIDR"
        _assert_eq "KUBEADM_API_ADDR default" "" "$KUBEADM_API_ADDR"
        _assert_eq "KUBEADM_CP_ENDPOINT default" "" "$KUBEADM_CP_ENDPOINT"
    )
}

# ============================================================
# Test: logging.sh functions
# ============================================================
test_logging() {
    echo "=== Test: logging.sh functions ==="
    source "$PROJECT_ROOT/lib/logging.sh"

    # Test log_error always outputs
    local out
    out=$(LOG_LEVEL=0 log_error "test error" 2>&1)
    _assert_eq "log_error outputs at level 0" "ERROR: test error" "$out"

    # Test log_info suppressed at level 0
    out=$(LOG_LEVEL=0 log_info "test info" 2>&1)
    _assert_eq "log_info suppressed at level 0" "" "$out"

    # Test log_info visible at level 1
    out=$(LOG_LEVEL=1 log_info "test info" 2>&1)
    _assert_eq "log_info visible at level 1" "test info" "$out"

    # Test log_debug suppressed at level 1
    out=$(LOG_LEVEL=1 log_debug "test debug" 2>&1)
    _assert_eq "log_debug suppressed at level 1" "" "$out"

    # Test log_debug visible at level 2
    out=$(LOG_LEVEL=2 log_debug "test debug" 2>&1)
    _assert_eq "log_debug visible at level 2" "DEBUG: test debug" "$out"
}

# ============================================================
# Test: file logging (_init_file_logging, _log_to_file)
# ============================================================
test_file_logging() {
    echo "=== Test: file logging ==="
    (
        source "$PROJECT_ROOT/lib/bootstrap.sh"
        source "$PROJECT_ROOT/lib/variables.sh"
        source "$PROJECT_ROOT/lib/logging.sh"

        # Test _init_file_logging creates a log file
        local tmpdir
        tmpdir=$(mktemp -d /tmp/test-logdir-XXXXXX)
        _init_file_logging "$tmpdir"
        local has_file="false"
        [ -n "$_LOG_FILE" ] && [ -f "$_LOG_FILE" ] && has_file="true"
        _assert_eq "log file created" "true" "$has_file"

        # Test log_info writes to file
        log_info "test message from unit test"
        local has_msg="false"
        if grep -q "test message from unit test" "$_LOG_FILE" 2>/dev/null; then
            has_msg="true"
        fi
        _assert_eq "log_info writes to file" "true" "$has_msg"

        # Test log_error writes to file
        log_error "test error message" 2>/dev/null
        local has_err="false"
        if grep -q "ERROR: test error message" "$_LOG_FILE" 2>/dev/null; then
            has_err="true"
        fi
        _assert_eq "log_error writes to file" "true" "$has_err"

        rm -rf "$tmpdir"
    )
}

# ============================================================
# Test: audit logging (_audit_log)
# ============================================================
test_audit_logging() {
    echo "=== Test: audit logging ==="
    (
        source "$PROJECT_ROOT/lib/bootstrap.sh"
        source "$PROJECT_ROOT/lib/variables.sh"
        source "$PROJECT_ROOT/lib/logging.sh"

        # Init file logging so audit events go to a file
        local tmpdir
        tmpdir=$(mktemp -d /tmp/test-auditdir-XXXXXX)
        _init_file_logging "$tmpdir"

        _audit_log "deploy" "started" "nodes=3"
        local has_audit="false"
        if grep -q "AUDIT:.*op=deploy.*outcome=started.*nodes=3" "$_LOG_FILE" 2>/dev/null; then
            has_audit="true"
        fi
        _assert_eq "audit log entry written" "true" "$has_audit"

        # Verify audit format contains ts= and user=
        local has_ts="false"
        if grep -q "AUDIT: ts=" "$_LOG_FILE" 2>/dev/null; then
            has_ts="true"
        fi
        _assert_eq "audit log has timestamp" "true" "$has_ts"

        local has_user="false"
        if grep -q "user=" "$_LOG_FILE" 2>/dev/null; then
            has_user="true"
        fi
        _assert_eq "audit log has user" "true" "$has_user"

        rm -rf "$tmpdir"
    )
}
