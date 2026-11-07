#!/usr/bin/env bats
# shellcheck disable=SC2034 # tests set globals read by the modules under test
# Cluster configuration file (--config, lib/remote/config.sh).

setup() {
    load '../helpers/common'
    load_modules
    quiet_logs
    CFG="$BATS_TEST_TMPDIR/cluster.yaml"
    cat > "$CFG" <<'EOF'
nodes:
  - address: 10.0.0.1
    role: control-plane
  - address: 10.0.0.2
    role: control-plane
  - address: 10.0.0.11
    role: worker
    node-ip: 192.168.10.11
    ssh:
      user: admin
      port: 2222
      key: keys/worker

ssh:
  user: ubuntu
  key: ~/.ssh/id_ed25519

kubernetes:
  version: "1.37"
  cri: crio
  patches: ./kubeadm-patches
  swap-enabled: true

network:
  apiserver-cert-extra-sans: [k8s.example.com, 10.0.0.100]

ha:
  vip: 10.0.0.100

tools:
  completion:
    shells:
      - bash
      - zsh
EOF
}

# The arguments config_load produced, one per line
_args() { eval "printf '%s\\n' $_CONFIG_ARGS"; }

@test "deploy gets the nodes, the cluster options, and paths relative to the file" {
    config_load deploy "$CFG"
    args=$(_args)
    [[ "$args" == *$'--control-planes\n10.0.0.1,10.0.0.2'* ]]
    [[ "$args" == *$'--workers\nadmin@10.0.0.11'* ]]
    [[ "$args" == *$'--ssh-user\nubuntu'* ]]
    [[ "$args" == *$'--ssh-key\n'"$HOME"'/.ssh/id_ed25519'* ]]
    [[ "$args" == *$'--kubernetes-version\n1.37'* ]]
    [[ "$args" == *$'--patches\n'"$BATS_TEST_TMPDIR"'/kubeadm-patches'* ]]
    [[ "$args" == *$'--apiserver-cert-extra-sans\nk8s.example.com,10.0.0.100'* ]]
    [[ "$args" == *$'--completion-shells\nbash,zsh'* ]]
    [[ "$args" == *$'--swap-enabled'* ]]
    [[ "$args" == *$'--ha-vip\n10.0.0.100'* ]]
}

@test "other commands get only what they use" {
    config_load backup "$CFG"
    args=$(_args)
    [[ "$args" == *$'--control-planes\n10.0.0.1'* ]]
    [[ "$args" != *"10.0.0.2"* ]]
    [[ "$args" != *"--cri"* ]] && [[ "$args" != *"--kubernetes-version"* ]]
    [[ "$args" == *$'--ssh-user\nubuntu'* ]]
    config_load upgrade "$CFG"
    args=$(_args)
    [[ "$args" == *$'--kubernetes-version\n1.37'* ]] && [[ "$args" == *"--workers"* ]] && [[ "$args" != *"--cri"* ]]
}

@test "per-node SSH port and key, and kubelet node IP" {
    config_load deploy "$CFG"
    [ "$(node_override 10.0.0.11 port)" = 2222 ]
    [ "$(node_override 10.0.0.11 key)" = "$BATS_TEST_TMPDIR/keys/worker" ]
    [ "$(node_override 10.0.0.11 node-ip)" = 192.168.10.11 ]
    [ -z "$(node_override 10.0.0.1 port)" ]
    DEPLOY_SSH_PORT=22 DEPLOY_SSH_KEY=/k
    _build_deploy_ssh_opts 10.0.0.11
    [[ "$_SSH_OPTS" == *"-p 2222 -i $BATS_TEST_TMPDIR/keys/worker"* ]]
    _build_deploy_ssh_opts 10.0.0.1
    [[ "$_SSH_OPTS" == *"-p 22 -i /k"* ]]
}

@test "unknown keys, bad roles, and nodes without an address are errors" {
    printf 'kubernetes:\n  versoin: "1.37"\n' > "$CFG"
    run config_load deploy "$CFG"
    [ "$status" -ne 0 ]
    printf 'nodes:\n  - address: 10.0.0.1\n    role: master\n' > "$CFG"
    run config_load deploy "$CFG"
    [ "$status" -ne 0 ]
    printf 'nodes:\n  - role: worker\n' > "$CFG"
    run config_load deploy "$CFG"
    [ "$status" -ne 0 ]
}

@test "options on the command line replace those of the file" {
    config_load deploy "$CFG" " --kubernetes-version --workers"
    args=$(_args)
    [[ "$args" != *"--kubernetes-version"* ]] && [[ "$args" != *"--workers"* ]]
    [[ "$args" == *"--control-planes"* ]] && [[ "$args" == *"--cri"* ]]
    cd "$BATS_TEST_TMPDIR" || return 1
    mkdir -p kubeadm-patches
    run sh "$PROJECT_ROOT/setup-k8s.sh" deploy --config "$CFG" --kubernetes-version 1.38 --dry-run
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c -x -- '--kubernetes-version')" -eq 1 ]
    [[ "$output" == *$'--kubernetes-version\n1.38'* ]]
}
