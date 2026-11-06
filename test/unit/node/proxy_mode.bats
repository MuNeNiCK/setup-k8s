#!/usr/bin/env bats
# shellcheck disable=SC2034 # tests set globals read by the modules under test
# kube-proxy mode selection (--proxy-mode auto) and the kernel version check.

setup() {
    load '../helpers/common'
    load_modules
    quiet_logs
    fake_cmd modprobe 0
}

@test "_kernel_version_ge compares the running kernel" {
    _kernel_release() { echo "6.8.0-147-generic"; }
    _kernel_version_ge 5.13
    _kernel_version_ge 6.8
    run ! _kernel_version_ge 6.9
    _kernel_release() { echo "5.14.0-570.el9.x86_64"; }
    _kernel_version_ge 5.13
    _kernel_release() { echo "4.18.0-553.el8_10.x86_64"; }
    run ! _kernel_version_ge 5.13
    _kernel_release() { echo "5.4-rc1"; }
    run ! _kernel_version_ge 5.13
}

@test "auto selects nftables on Kubernetes 1.33+ with kernel 5.13+" {
    _kernel_release() { echo "6.8.0"; }
    [ "$(_resolve_auto_proxy_mode 1.37)" = nftables ]
    [ "$(_resolve_auto_proxy_mode 1.33)" = nftables ]
    [ "$(_resolve_auto_proxy_mode "")" = nftables ]
}

@test "auto selects iptables for older Kubernetes or kernels" {
    _kernel_release() { echo "6.8.0"; }
    [ "$(_resolve_auto_proxy_mode 1.32)" = iptables ]
    _kernel_release() { echo "4.18.0-553.el8_10.x86_64"; }
    [ "$(_resolve_auto_proxy_mode 1.37)" = iptables ]
}

@test "auto selects iptables when nf_tables is not available" {
    _kernel_release() { echo "6.8.0"; }
    fake_cmd modprobe 1
    if [ -d /sys/module/nf_tables ]; then
        skip "nf_tables is loaded on this host"
    fi
    [ "$(_resolve_auto_proxy_mode 1.37)" = iptables ]
}

@test "resolve_proxy_mode replaces auto and keeps explicit modes" {
    _kernel_release() { echo "6.8.0"; }
    K8S_VERSION=1.37
    PROXY_MODE=auto
    resolve_proxy_mode
    [ "$PROXY_MODE" = nftables ]
    PROXY_MODE=ipvs
    resolve_proxy_mode
    [ "$PROXY_MODE" = ipvs ]
}

@test "auto is the default and is accepted by init and preflight" {
    [ "$PROXY_MODE" = auto ]
    [ "$PREFLIGHT_PROXY_MODE" = auto ]
    parse_setup_args --proxy-mode auto
    [ "$PROXY_MODE" = auto ]
    run parse_preflight_args --proxy-mode bogus
    [ "$status" -ne 0 ]
}
