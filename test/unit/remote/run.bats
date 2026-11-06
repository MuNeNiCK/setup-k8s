#!/usr/bin/env bats
# shellcheck disable=SC2034 # tests set globals read by the modules under test
# Remote execution interface (lib/remote/run.sh). The SSH transport is
# replaced by recorders; assertions check the command a node would run.

setup() {
    load '../helpers/common'
    load_modules
    quiet_logs
    RUNS="$BATS_TEST_TMPDIR/runs"
    : > "$RUNS"
    _deploy_exec_remote() { printf '%s@%s|%s|%s\n' "$1" "$2" "$3" "$4" >> "$RUNS"; }
    DEPLOY_SSH_USER=root
    _bundle_dir_set 10.0.0.1 /tmp/sk-a
    _bundle_dir_set 10.0.0.2 /tmp/sk-b
}

@test "remote_run runs the transferred script with quoted arguments" {
    remote_run 10.0.0.1 "kubeadm init" init --pod-network-cidr "10.244.0.0/16"
    [ "$(cat "$RUNS")" = "root@10.0.0.1|kubeadm init|sh '/tmp/sk-a/setup-k8s.sh' 'init' '--pod-network-cidr' '10.244.0.0/16' " ]
}

@test "remote_run uses sudo -n for non-root users" {
    remote_run admin@10.0.0.2 "join" join --join-token abc
    grep -q "^admin@10.0.0.2|join|sudo -n sh '/tmp/sk-b/setup-k8s.sh' 'join' '--join-token' 'abc' $" "$RUNS"
}

@test "remote_run forwards collected args and drops flags with their values" {
    local fwd
    fwd=$(_passthrough_add_pair "" --ha-vip 10.0.0.100)
    fwd=$(_passthrough_add_pair "$fwd" --cri crio)
    fwd=$(_passthrough_add_flag "$fwd" --swap-enabled)
    remote_run --forward "$fwd" --drop "--ha-vip --ha-interface" 10.0.0.2 "join worker" join
    [ "$(cut -d'|' -f3 "$RUNS")" = "sh '/tmp/sk-b/setup-k8s.sh' 'join' '--cri' 'crio' '--swap-enabled' " ]
}

@test "remote_run drops boolean flags without consuming the next argument" {
    local fwd
    fwd=$(_passthrough_add_flag "" --skip-drain)
    fwd=$(_passthrough_add_pair "$fwd" --distro rhel)
    remote_run --forward "$fwd" --drop "--kubernetes-version --skip-drain" 10.0.0.1 "rollback" upgrade --rollback-to 1.36.6
    [ "$(cut -d'|' -f3 "$RUNS")" = "sh '/tmp/sk-a/setup-k8s.sh' 'upgrade' '--rollback-to' '1.36.6' '--distro' 'rhel' " ]
}

@test "remote_run passes environment variables" {
    remote_run --env "UPGRADE_ADMIN_CONF=/tmp/admin conf" 10.0.0.2 "upgrade" upgrade --kubernetes-version 1.37.2
    [ "$(cut -d'|' -f3 "$RUNS")" = "env 'UPGRADE_ADMIN_CONF=/tmp/admin conf' sh '/tmp/sk-b/setup-k8s.sh' 'upgrade' '--kubernetes-version' '1.37.2' " ]
}

@test "remote_run fails for a node without a transferred script" {
    run remote_run 10.0.0.9 "init" init
    [ "$status" -ne 0 ]
    [ ! -s "$RUNS" ]
}

@test "remote_node_dir returns the node working directory" {
    [ "$(remote_node_dir root@10.0.0.2)" = "/tmp/sk-b" ]
}

@test "rollback runs upgrade --rollback-to, which accepts an older version" {
    UPGRADE_PASSTHROUGH_ARGS=$(_passthrough_add_pair "" --kubernetes-version 1.37.2)
    _rollback_node 10.0.0.1 1.36.6
    [ "$(cut -d'|' -f3 "$RUNS")" = "sh '/tmp/sk-a/setup-k8s.sh' 'upgrade' '--rollback-to' '1.36.6' " ]

    # The node side parses the command without the forward-upgrade checks
    UPGRADE_TARGET_VERSION=""
    parse_upgrade_local_args --rollback-to 1.36.6
    [ "$UPGRADE_ROLLBACK_VERSION" = "1.36.6" ]
}

@test "local rollback reinstalls packages at the previous version" {
    CALLS="$BATS_TEST_TMPDIR/calls"
    k8s_upgrade_kubeadm() { echo "kubeadm $1" >> "$CALLS"; }
    k8s_upgrade_node() { echo "node $1" >> "$CALLS"; }
    _get_current_k8s_version() { echo 1.37.2; }
    _service_reload() { :; }
    _service_restart() { :; }
    show_versions() { :; }
    UPGRADE_ROLLBACK_VERSION=1.36.6
    rollback_node_local
    [ "$(cat "$CALLS")" = "kubeadm 1.36.6
node 1.36.6" ]
}

@test "local rollback refuses to skip minor versions" {
    _get_current_k8s_version() { echo 1.37.2; }
    UPGRADE_ROLLBACK_VERSION=1.35.1
    run rollback_node_local
    [ "$status" -ne 0 ]
}
