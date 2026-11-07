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
