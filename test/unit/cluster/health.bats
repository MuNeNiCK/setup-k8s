#!/usr/bin/env bats
# Ported from test/unit/test_health.sh

setup() {
    load '../helpers/common'
}

# File-local module loader
_load_health_test_modules() {
    load_modules
}

# ============================================================
# Test: health.sh functions exist
# ============================================================
_case_health_functions() {
    echo "=== Test: health.sh functions exist ==="
    (
        _load_health_test_modules

        # Verify all health check functions are defined
        local has_api="false"
        type _health_check_api_server >/dev/null 2>&1 && has_api="true"
        _assert_eq "_health_check_api_server defined" "true" "$has_api"

        local has_nodes="false"
        type _health_check_nodes_ready >/dev/null 2>&1 && has_nodes="true"
        _assert_eq "_health_check_nodes_ready defined" "true" "$has_nodes"

        local has_etcd="false"
        type _health_check_etcd >/dev/null 2>&1 && has_etcd="true"
        _assert_eq "_health_check_etcd defined" "true" "$has_etcd"

        local has_pods="false"
        type _health_check_core_pods >/dev/null 2>&1 && has_pods="true"
        _assert_eq "_health_check_core_pods defined" "true" "$has_pods"

        local has_cluster="false"
        type _health_check_cluster >/dev/null 2>&1 && has_cluster="true"
        _assert_eq "_health_check_cluster defined" "true" "$has_cluster"
    )
}

@test "health.sh functions exist" {
    _case_health_functions
}
