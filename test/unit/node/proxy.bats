#!/usr/bin/env bats
# shellcheck disable=SC2034 # tests set globals read by the modules under test
# HTTP proxy settings (lib/node/proxy.sh).

setup() {
    load '../helpers/common'
    load_modules
    quiet_logs
    unset http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY
    _PROXY_SYSTEMD_DIR="$BATS_TEST_TMPDIR/systemd"
    _PROXY_OPENRC_CONF_DIR="$BATS_TEST_TMPDIR/conf.d"
    _service_reload() { :; }
    fake_cmd ip 0 "2: eth0    inet 10.0.0.5/24 brd 10.0.0.255 scope global eth0"
}

@test "options are validated and parsed" {
    _parse_proxy_flag 2 --https-proxy http://proxy:3128
    [ "$HTTPS_PROXY_URL" = http://proxy:3128 ] && [ "$_PROXY_SHIFT" -eq 2 ]
    run _parse_proxy_flag 2 --http-proxy proxy:3128
    [ "$status" -ne 0 ]
    _is_proxy_flag --no-proxy
    run _is_proxy_flag --proxy-mode
    [ "$status" -ne 0 ]
}

@test "NO_PROXY adds the cluster's addresses and networks to the given list" {
    HTTPS_PROXY_URL=http://proxy:3128 NO_PROXY_LIST=".example.com"
    KUBEADM_POD_CIDR=10.244.0.0/16 KUBEADM_CP_ENDPOINT="[fd00::10]:6443" HA_VIP_ADDRESS=10.0.0.100
    proxy_apply_env
    for item in .example.com localhost 127.0.0.1 ::1 .svc .cluster.local 10.96.0.0/12 10.244.0.0/16 fd00::10 10.0.0.100 10.0.0.5; do
        [[ ",$NO_PROXY," == *",$item,"* ]] || { echo "missing $item in $NO_PROXY"; return 1; }
    done
    [ "$https_proxy" = http://proxy:3128 ] && [ "$no_proxy" = "$NO_PROXY" ]
    # No duplicates
    [ "$(echo "$NO_PROXY" | tr ',' '\n' | sort | uniq -d)" = "" ]
}

@test "the environment is used only without options" {
    https_proxy=http://env-proxy:8080 no_proxy=.corp
    proxy_apply_env
    [ "$HTTPS_PROXY_URL" = http://env-proxy:8080 ]
    [[ "$NO_PROXY" == .corp,* ]]
    HTTPS_PROXY_URL=http://option:3128 NO_PROXY_LIST=""
    https_proxy=http://env-proxy:8080
    proxy_apply_env
    [ "$HTTPS_PROXY" = http://option:3128 ]
}

@test "no proxy: nothing is exported or written" {
    proxy_apply_env
    [ -z "${HTTPS_PROXY:-}" ] && [ -z "${NO_PROXY:-}" ]
    _detect_init_system() { echo systemd; }
    proxy_configure_runtime containerd
    [ ! -e "$_PROXY_SYSTEMD_DIR/containerd.service.d" ]
}

@test "systemd: the runtime gets a drop-in, with % escaped" {
    _detect_init_system() { echo systemd; }
    HTTPS_PROXY_URL='http://user:p%40ss@proxy:3128'
    proxy_apply_env
    proxy_configure_runtime crio
    f="$_PROXY_SYSTEMD_DIR/crio.service.d/10-setup-k8s-proxy.conf"
    grep -qx '\[Service\]' "$f"
    grep -qxF 'Environment="HTTPS_PROXY=http://user:p%%40ss@proxy:3128"' "$f"
    grep -q '^Environment="NO_PROXY=.*10.96.0.0/12' "$f"
    proxy_cleanup
    [ ! -e "$f" ] && [ ! -e "$_PROXY_SYSTEMD_DIR/crio.service.d" ]
}

@test "OpenRC: a managed block in conf.d, replaced on reruns and removed on cleanup" {
    _detect_init_system() { echo openrc; }
    mkdir -p "$_PROXY_OPENRC_CONF_DIR"
    echo 'containerd_opts="--log-level info"' > "$_PROXY_OPENRC_CONF_DIR/containerd"
    HTTP_PROXY_URL=http://proxy:3128
    proxy_apply_env
    proxy_configure_runtime containerd
    proxy_configure_runtime containerd
    f="$_PROXY_OPENRC_CONF_DIR/containerd"
    [ "$(grep -c "^# BEGIN setup-k8s proxy" "$f")" -eq 1 ]
    grep -qxF "export HTTP_PROXY='http://proxy:3128'" "$f"
    proxy_cleanup
    [ "$(cat "$f")" = 'containerd_opts="--log-level info"' ]
}

@test "the running runtime must have the proxy environment" {
    HTTPS_PROXY_URL=http://proxy:3128
    proxy_apply_env
    HTTPS_PROXY=http://proxy:3128 sleep 30 &
    with_proxy=$!
    env -u HTTPS_PROXY -u https_proxy sleep 30 &
    without=$!
    pidof() { echo "$PIDOF"; }
    PIDOF=$with_proxy
    proxy_verify_runtime containerd
    PIDOF=$without
    run proxy_verify_runtime containerd
    [ "$status" -ne 0 ]
    kill "$with_proxy" "$without"
}

@test "remote commands forward only the options" {
    https_proxy=http://env-proxy:8080
    [ -z "$(proxy_forward_args "")" ]
    HTTPS_PROXY_URL=http://proxy:3128 NO_PROXY_LIST=.corp
    out=$(proxy_forward_args "")
    [ "$out" = "$(printf '%s\n%s\n%s\n%s' --https-proxy http://proxy:3128 --no-proxy .corp)" ]
}
