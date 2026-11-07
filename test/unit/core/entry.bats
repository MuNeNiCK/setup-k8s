#!/usr/bin/env bats
# Entry point and single-file bundle behavior (run as a user would run them).

setup() {
    load '../helpers/common'
    BUNDLE="$BATS_TEST_TMPDIR/setup-k8s.sh"
    sh "$PROJECT_ROOT/scripts/build.sh" "$BUNDLE" "v9.9.9-test" >/dev/null
    KEY="$BATS_TEST_TMPDIR/id_test"
    : > "$KEY"
    chmod 600 "$KEY"
}

@test "build writes the bundle and a matching sha256" {
    [ -f "$BUNDLE" ]
    [ -f "$BUNDLE.sha256" ]
    (cd "$BATS_TEST_TMPDIR" && sha256sum -c setup-k8s.sh.sha256 >/dev/null)
    head -n 4 "$BUNDLE" | grep -qx 'BUNDLED_MODE=true'
    head -n 4 "$BUNDLE" | grep -qx "SETUP_K8S_VERSION='v9.9.9-test'"
}

@test "--version prints the embedded version (file and stdin)" {
    run sh "$BUNDLE" --version
    [ "$status" -eq 0 ]
    [ "$output" = "setup-k8s v9.9.9-test" ]

    run sh -c "sh -s -- --version < '$BUNDLE'"
    [ "$status" -eq 0 ]
    [ "$output" = "setup-k8s v9.9.9-test" ]
}

@test "--version from a checkout prints dev" {
    run sh "$PROJECT_ROOT/setup-k8s.sh" --version
    [ "$status" -eq 0 ]
    [ "$output" = "setup-k8s dev" ]
}

@test "global help lists subcommands" {
    run sh "$BUNDLE" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: setup-k8s.sh <subcommand> [options]"* ]]
    [[ "$output" == *"deploy"* ]]
    [[ "$output" == *"--log-dir DIR"* ]]
}

@test "subcommand help is shown without root" {
    run sh "$BUNDLE" init --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--cri RUNTIME"* ]]

    run sh "$BUNDLE" cleanup --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--preserve-cni"* ]]
}

@test "missing or unknown subcommand fails" {
    run sh "$BUNDLE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Missing subcommand"* ]]

    run sh "$BUNDLE" frobnicate
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown subcommand 'frobnicate'"* ]]
}

@test "subcommand options must follow the subcommand" {
    run sh "$BUNDLE" --cri crio init
    [ "$status" -eq 1 ]
    [[ "$output" == *"'--cri' must follow the subcommand"* ]]
}

@test "remote subcommands refuse to run from stdin" {
    run sh -c "sh -s -- deploy --control-planes root@192.0.2.10 --ssh-key '$KEY' < '$BUNDLE'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"must be run from a downloaded file"* ]]
}

@test "remote subcommand dry-run works from stdin" {
    run sh -c "sh -s -- deploy --control-planes root@192.0.2.10 --ssh-key '$KEY' --dry-run < '$BUNDLE'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Deploy Dry-Run Plan"* ]]
}

@test "entry script without lib/ points to the release asset" {
    cp "$PROJECT_ROOT/setup-k8s.sh" "$BATS_TEST_TMPDIR/lonely.sh"
    run sh "$BATS_TEST_TMPDIR/lonely.sh" init
    [ "$status" -eq 1 ]
    [[ "$output" == *"releases/latest/download/setup-k8s.sh"* ]]
}

@test "bundle transfers itself: generate_deploy_bundle copies the running file" {
    load_modules
    # shellcheck disable=SC2034 # read by generate_deploy_bundle
    BUNDLED_MODE=true
    # shellcheck disable=SC2034 # read by generate_deploy_bundle
    _SELF_PATH="$BUNDLE"
    generate_deploy_bundle "$BATS_TEST_TMPDIR/copy.sh"
    cmp "$BUNDLE" "$BATS_TEST_TMPDIR/copy.sh"
}

@test "the source entry point alone (earlier raw/main URL) points to the release asset" {
    cp "$PROJECT_ROOT/setup-k8s.sh" "$BATS_TEST_TMPDIR/setup-k8s.sh"
    # From a directory without the repository (as after curl ... | sh)
    run sh -c 'cd "$1" && sh -s -- init < setup-k8s.sh' _ "$BATS_TEST_TMPDIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"releases/latest/download/setup-k8s.sh | sudo sh -s --"* ]]
}
