#!/usr/bin/env bats
# shellcheck disable=SC2034 # tests set globals read by the modules under test
# _deploy_exec_remote: completion detection for detached remote commands.
# The "remote" side runs locally: _deploy_ssh executes its command with sh.

setup() {
    load '../helpers/common'
    load_modules
    _deploy_ssh() { sh -c "$3"; }
    DEPLOY_POLL_INTERVAL=1
    DEPLOY_REMOTE_TIMEOUT=20
}

@test "a successful command completes" {
    run _deploy_exec_remote root node1 "test" "echo hello"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Completed: test"* ]]
}

@test "a failing command reports its exit status" {
    run _deploy_exec_remote root node1 "test" "echo boom; exit 3"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Failed (exit 3): test"* ]]
    [[ "$output" == *"boom"* ]]
}

@test "a command that finishes at the last poll is not a timeout" {
    DEPLOY_REMOTE_TIMEOUT=1
    run _deploy_exec_remote root node1 "test" "true"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Timeout"* ]]
}

@test "a command that dies without an exit status fails at the next poll" {
    # Kill the detached wrapper so that no exit status is written
    SECONDS=0
    run _deploy_exec_remote root node1 "test" 'kill -9 $PPID; sleep 30'
    [ "$status" -eq 1 ]
    [[ "$output" == *"ended without an exit status"* ]]
    [ "$SECONDS" -lt 15 ]
}

@test "a command still running at the timeout is reported as a timeout" {
    DEPLOY_REMOTE_TIMEOUT=2
    run _deploy_exec_remote root node1 "test" "sleep 10"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Timeout after 2s: test"* ]]
}

@test "transient SSH failures while polling are retried" {
    POLLS="$BATS_TEST_TMPDIR/polls"
    : > "$POLLS"
    _deploy_ssh() {
        case "$3" in
            *"echo running"*)
                echo x >> "$POLLS"
                # The first poll fails like a dropped connection
                if [ "$(wc -l < "$POLLS")" -eq 1 ]; then
                    echo "Connection reset by peer" >&2
                    return 255
                fi
                ;;
        esac
        sh -c "$3"
    }
    run _deploy_exec_remote root node1 "test" "sleep 2"
    [ "$status" -eq 0 ]
}
