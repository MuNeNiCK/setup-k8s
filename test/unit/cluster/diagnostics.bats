#!/usr/bin/env bats
# Ported from test/unit/test_diagnostics.sh

setup() {
    load '../helpers/common'
}

# File-local module loader
_load_diagnostics_test_modules() {
    load_modules
}

# ============================================================
# Test: diagnostics functions exist
# ============================================================
_case_diagnostics_functions() {
    echo "=== Test: diagnostics functions exist ==="
    (
        _load_diagnostics_test_modules

        local has_remote="false"
        type _collect_diagnostics >/dev/null 2>&1 && has_remote="true"
        _assert_eq "_collect_diagnostics defined" "true" "$has_remote"

        local has_local="false"
        type _collect_local_diagnostics >/dev/null 2>&1 && has_local="true"
        _assert_eq "_collect_local_diagnostics defined" "true" "$has_local"
    )
}

@test "diagnostics functions exist" {
    _case_diagnostics_functions
}
