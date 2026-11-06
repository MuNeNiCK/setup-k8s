#!/usr/bin/env bats
# Ported from test/unit/test_state.sh

setup() {
    load '../helpers/common'
}

# File-local module loader
_load_state_test_modules() {
    load_modules
    log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
}

# ============================================================
# Test: state module functions defined
# ============================================================
_case_state_functions_defined() {
    echo "=== Test: state module functions defined ==="
    (
        _load_state_test_modules

        local has_init="false"
        type _state_init >/dev/null 2>&1 && has_init="true"
        _assert_eq "_state_init defined" "true" "$has_init"

        local has_set="false"
        type _state_set >/dev/null 2>&1 && has_set="true"
        _assert_eq "_state_set defined" "true" "$has_set"

        local has_get="false"
        type _state_get >/dev/null 2>&1 && has_get="true"
        _assert_eq "_state_get defined" "true" "$has_get"

        local has_mark="false"
        type _state_mark_step >/dev/null 2>&1 && has_mark="true"
        _assert_eq "_state_mark_step defined" "true" "$has_mark"

        local has_find="false"
        type _state_find_resume >/dev/null 2>&1 && has_find="true"
        _assert_eq "_state_find_resume defined" "true" "$has_find"

        local has_load="false"
        type _state_load >/dev/null 2>&1 && has_load="true"
        _assert_eq "_state_load defined" "true" "$has_load"

        local has_complete="false"
        type _state_complete >/dev/null 2>&1 && has_complete="true"
        _assert_eq "_state_complete defined" "true" "$has_complete"
    )
}

# ============================================================
# Test: state set/get
# ============================================================
_case_state_set_get() {
    echo "=== Test: state set/get ==="
    (
        _load_state_test_modules

        # Override state dir to use a temp directory
        _STATE_DIR=$(mktemp -d /tmp/test-state-XXXXXX)
        _state_init "test-op"

        _state_set "mykey" "myvalue"
        local val
        val=$(_state_get "mykey")
        _assert_eq "state get mykey" "myvalue" "$val"

        # Update the same key
        _state_set "mykey" "newvalue"
        val=$(_state_get "mykey")
        _assert_eq "state get mykey updated" "newvalue" "$val"

        # Non-existent key
        val=$(_state_get "nonexistent")
        _assert_eq "state get nonexistent" "" "$val"

        _state_cleanup
        rm -rf "$_STATE_DIR"
    )
}

# ============================================================
# Test: state mark step done
# ============================================================
_case_state_mark_step_done() {
    echo "=== Test: state mark step done ==="
    (
        _load_state_test_modules

        _STATE_DIR=$(mktemp -d /tmp/test-state-XXXXXX)
        _state_init "test-op"

        _state_mark_step "bundle" "done"
        local is_done="false"
        _state_is_step_done "bundle" && is_done="true"
        _assert_eq "step bundle is done" "true" "$is_done"

        is_done="false"
        _state_is_step_done "transfer" && is_done="true"
        _assert_eq "step transfer not done" "false" "$is_done"

        _state_cleanup
        rm -rf "$_STATE_DIR"
    )
}

# ============================================================
# Test: state find resume
# ============================================================
_case_state_find_resume() {
    echo "=== Test: state find resume ==="
    (
        _load_state_test_modules

        _STATE_DIR=$(mktemp -d /tmp/test-state-XXXXXX)
        _state_init "myop"

        local found
        found=$(_state_find_resume "myop")
        _assert_ne "find resume returns a file" "" "$found"

        # Complete it, should no longer be resumable
        _state_complete
        found=$(_state_find_resume "myop")
        _assert_eq "find resume after complete" "" "$found"

        rm -rf "$_STATE_DIR"
    )
}

# ============================================================
# Test: RESUME_ENABLED default
# ============================================================
_case_resume_enabled_default() {
    echo "=== Test: RESUME_ENABLED default ==="
    (
        load_modules
        _assert_eq "RESUME_ENABLED default" "false" "$RESUME_ENABLED"
    )
}

@test "state module functions defined" {
    _case_state_functions_defined
}

@test "state set/get" {
    _case_state_set_get
}

@test "state mark step done" {
    _case_state_mark_step_done
}

@test "state find resume" {
    _case_state_find_resume
}

@test "RESUME_ENABLED default" {
    _case_resume_enabled_default
}
