#!/bin/sh

# Cluster health check module: verify cluster readiness before/after operations.
# Provides pre-operation and post-operation health checks for deploy, upgrade, remove.

# Check API server responsiveness via kubectl.
# Usage: _health_check_api_server <user> <host>
_health_check_api_server() {
    local user="$1" host="$2"
    local pfx; pfx=$(_sudo_prefix "$user")

    log_info "  Checking API server responsiveness..."
    if _deploy_ssh "$user" "$host" "${pfx}kubectl --kubeconfig=/etc/kubernetes/admin.conf get --raw /readyz" >/dev/null 2>&1; then
        log_info "  API server: ready"
        return 0
    else
        log_warn "  API server: not ready"
        return 1
    fi
}

# Check that all nodes are in Ready state.
# Usage: _health_check_nodes_ready <user> <host>
_health_check_nodes_ready() {
    local user="$1" host="$2"
    local pfx; pfx=$(_sudo_prefix "$user")

    log_info "  Checking node readiness..."
    local nodes_output
    nodes_output=$(_deploy_ssh "$user" "$host" "${pfx}kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes --no-headers" 2>/dev/null) || true
    if [ -z "$nodes_output" ]; then
        log_warn "  Could not retrieve node list"
        return 1
    fi

    local not_ready=""
    echo "$nodes_output" | while IFS= read -r line; do
        local name status
        name=$(echo "$line" | awk '{print $1}')
        status=$(echo "$line" | awk '{print $2}')
        case "$status" in
            Ready) ;;
            *) not_ready="${not_ready}${not_ready:+, }${name}(${status})" ;;
        esac
    done

    # Re-check for NotReady nodes (subshell above doesn't propagate)
    local not_ready_count
    not_ready_count=$(echo "$nodes_output" | awk '$2 != "Ready" {count++} END {print count+0}')
    if [ "$not_ready_count" -gt 0 ]; then
        local not_ready_names
        not_ready_names=$(echo "$nodes_output" | awk '$2 != "Ready" {printf "%s(%s) ", $1, $2}')
        log_warn "  Not ready nodes: ${not_ready_names}"
        return 1
    fi

    local total
    total=$(echo "$nodes_output" | wc -l | tr -d '[:space:]')
    log_info "  All ${total} node(s) are Ready"
    return 0
}

# Verify that the expected number of nodes are registered in the cluster.
# Usage: _verify_node_count <user> <host> <expected_count>
_verify_node_count() {
    local user="$1" host="$2" expected="$3"
    local pfx; pfx=$(_sudo_prefix "$user")

    local nodes_output
    nodes_output=$(_deploy_ssh "$user" "$host" "${pfx}kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes --no-headers" 2>/dev/null) || true
    if [ -z "$nodes_output" ]; then
        log_error "Could not retrieve node list for node count verification"
        return 1
    fi

    local actual
    actual=$(echo "$nodes_output" | wc -l | tr -d '[:space:]')
    if [ "$actual" -ne "$expected" ]; then
        log_error "Node count mismatch: expected ${expected}, got ${actual}"
        return 1
    fi
    log_info "Node count verified: ${actual}/${expected}"
    return 0
}

# Check etcd cluster health and quorum.
# Usage: _health_check_etcd <user> <host>
_health_check_etcd() {
    local user="$1" host="$2"
    local pfx; pfx=$(_sudo_prefix "$user")

    log_info "  Checking etcd health..."

    # Try using crictl to check etcd container
    local etcd_health
    etcd_health=$(_deploy_ssh "$user" "$host" "${pfx}kubectl --kubeconfig=/etc/kubernetes/admin.conf get --raw /healthz/etcd" 2>/dev/null) || true
    if [ "$etcd_health" = "ok" ]; then
        log_info "  etcd: healthy"
        return 0
    fi

    log_warn "  etcd health check returned: ${etcd_health:-no response}"
    return 1
}

# Check that core kube-system pods are running.
# Usage: _health_check_core_pods <user> <host>
_health_check_core_pods() {
    local user="$1" host="$2"
    local pfx; pfx=$(_sudo_prefix "$user")

    log_info "  Checking core kube-system pods..."
    local pods_output
    pods_output=$(_deploy_ssh "$user" "$host" "${pfx}kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -n kube-system --no-headers" 2>/dev/null) || true
    if [ -z "$pods_output" ]; then
        log_warn "  Could not retrieve kube-system pods"
        return 1
    fi

    local not_running
    not_running=$(echo "$pods_output" | awk '$3 != "Running" && $3 != "Completed" {count++} END {print count+0}')
    if [ "$not_running" -gt 0 ]; then
        local problem_pods
        problem_pods=$(echo "$pods_output" | awk '$3 != "Running" && $3 != "Completed" {printf "%s(%s) ", $1, $3}')
        log_warn "  Non-running kube-system pods: ${problem_pods}"
        return 1
    fi

    local total
    total=$(echo "$pods_output" | wc -l | tr -d '[:space:]')
    log_info "  All ${total} kube-system pod(s) are Running/Completed"
    return 0
}

# Run all health checks (pre or post operation).
# Returns 0 if all checks pass, 1 if any fail (warnings only, non-fatal).
# Usage: _health_check_cluster <user> <host> [--pre|--post]
_health_check_cluster() {
    local user="$1" host="$2" mode="${3:---post}"
    local failures=0

    case "$mode" in
        --pre)  log_info "Running pre-operation health checks..." ;;
        --post) log_info "Running post-operation health checks..." ;;
    esac

    _health_check_api_server "$user" "$host" || failures=$((failures + 1))
    _health_check_nodes_ready "$user" "$host" || failures=$((failures + 1))
    _health_check_etcd "$user" "$host" || failures=$((failures + 1))
    _health_check_core_pods "$user" "$host" || failures=$((failures + 1))

    if [ "$failures" -gt 0 ]; then
        log_warn "Health check: ${failures} check(s) failed"
        return 1
    fi

    log_info "Health check: all checks passed"
    return 0
}
