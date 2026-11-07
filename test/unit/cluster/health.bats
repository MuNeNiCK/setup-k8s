#!/usr/bin/env bats
# Ported from test/unit/test_health.sh

setup() {
    load '../helpers/common'
}

# File-local module loader
_load_health_test_modules() {
    load_modules
}

# --- deploy verification ---

# Fake kubectl over SSH. NODES_FILE holds the "get nodes" output (it can be
# changed while a check is waiting); API and ETCD hold the readyz/etcd replies.
_fake_cluster() {
    NODES_FILE="$BATS_TEST_TMPDIR/nodes"
    API=ok ETCD=ok
    _deploy_ssh() {
        case "$3" in
            *"get --raw /readyz"*) [ "$API" = ok ] ;;
            *"/healthz/etcd"*) echo "$ETCD" ;;
            *"get nodes --no-headers"*) cat "$NODES_FILE" ;;
            *"get pods -n kube-system"*) echo "coredns-1 0/1 Pending 0 1m" ;;
        esac
    }
    sleep() { :; }
}

@test "_verify_node_count waits for nodes that register after join returns" {
    load_modules; quiet_logs; _fake_cluster
    printf 'cp1 NotReady control-plane 1m v1.37.2\n' > "$NODES_FILE"
    POLLS=0
    sleep() { POLLS=$((POLLS + 1)); [ "$POLLS" -eq 2 ] && printf 'cp1 NotReady control-plane 1m v1.37.2\nw1 NotReady <none> 5s v1.37.2\n' > "$NODES_FILE"; :; }
    _verify_node_count root cp1 2 30
}

@test "_verify_node_count fails when nodes never register" {
    load_modules; quiet_logs; _fake_cluster
    printf 'cp1 NotReady control-plane 1m v1.37.2\n' > "$NODES_FILE"
    run _verify_node_count root cp1 2 10
    [ "$status" -ne 0 ]
}

@test "a new cluster without a CNI plugin passes verification" {
    load_modules; quiet_logs; _fake_cluster
    printf 'cp1 NotReady control-plane 1m v1.37.2\nw1 NotReady <none> 1m v1.37.2\n' > "$NODES_FILE"
    _verify_deployed_cluster root cp1 2
}

@test "verification fails when etcd is unhealthy or the API server never becomes ready" {
    load_modules; quiet_logs; _fake_cluster
    printf 'cp1 Ready control-plane 1m v1.37.2\n' > "$NODES_FILE"
    ETCD="[-]etcd failed"
    run _verify_deployed_cluster root cp1 1
    [ "$status" -ne 0 ]
    ETCD=ok API=down
    run _verify_deployed_cluster root cp1 1
    [ "$status" -ne 0 ]
}
