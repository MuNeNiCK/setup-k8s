#!/usr/bin/env bats
# shellcheck disable=SC2034 # tests set globals read by the modules under test
# --dry-run must not change the system: no package installs or index
# refreshes, no host preparation, no remote commands.

setup() {
    load '../helpers/common'
    load_modules
    CHANGES="$BATS_TEST_TMPDIR/changes"
    : > "$CHANGES"
    _require_root() { :; }
    _OS_RELEASE_FILE="$BATS_TEST_TMPDIR/os-release"
    printf '%s\n' 'ID=ubuntu' 'VERSION_ID="24.04"' 'VERSION_CODENAME=noble' > "$_OS_RELEASE_FILE"
    # Anything that changes the system records itself
    for fn in install_node_dependencies system_prepare pkg_refresh pkg_install pkg_remove pkg_repo_add \
              disable_swap disable_zram_swap enable_kernel_modules configure_network_settings \
              k8s_install containerd_install crio_install _deploy_ssh _deploy_scp _deploy_exec_remote; do
        eval "$fn() { echo \"$fn \$*\" >> \"\$CHANGES\"; }"
    done
    for cmd in apt-get apt-mark dnf zypper apk pacman kubeadm systemctl modprobe sysctl swapoff; do
        fake_cmd "$cmd"
    done
    fake_cmd curl 0 v1.37.2
    DRY_RUN=true
}

@test "init --dry-run installs nothing and prepares nothing" {
    run _run_setup --kubernetes-version 1.37
    [ "$status" -eq 0 ]
    [[ "$output" == *"End of dry-run"* ]]
    [ ! -s "$CHANGES" ]
    if fake_calls | grep -E -q '^(apt-get|apt-mark|dnf|zypper|apk|pacman|systemctl|sysctl|swapoff) '; then
        fake_calls
        return 1
    fi
}

@test "init --dry-run without curl reports the version as resolved during setup" {
    rm -f "$FAKE_BIN/curl"
    # Hide a curl installed on the test host
    command() { if [ "$1" = -v ] && [ "$2" = curl ]; then return 1; fi; builtin command "$@"; }
    run _run_setup
    [ "$status" -eq 0 ]
    [[ "$output" == *"(latest stable)"* ]]
    [ ! -s "$CHANGES" ]
}

@test "deploy --dry-run contacts no node" {
    run _run_deploy --control-planes 10.0.0.1 --workers 10.0.0.2
    [ "$status" -eq 0 ]
    [ ! -s "$CHANGES" ]
}

@test "upgrade --dry-run contacts no node" {
    run _run_upgrade --control-planes 10.0.0.1 --kubernetes-version 1.37.2
    [ "$status" -eq 0 ]
    [ ! -s "$CHANGES" ]
}
