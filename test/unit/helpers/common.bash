#!/bin/bash
# Common helpers for setup-k8s unit tests (bats-core).
#
# Usage in a test file:
#   setup() { load '../helpers/common'; }
#
# Provides:
#   load_modules       Source every setup-k8s module, as the entry point does.
#   fake_cmd NAME ...  Put a fake external command on PATH that records calls.
#   fake_calls         Print the recorded calls ("name arg1 arg2 ...").
#   _assert_eq / _assert_ne / _assert_exit_code
#                      Assertions that fail the test with a readable message.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export PROJECT_ROOT

# Fake command directory and call log, unique per test.
FAKE_BIN="${BATS_TEST_TMPDIR}/fakebin"
FAKE_LOG="${BATS_TEST_TMPDIR}/fake_calls.log"
mkdir -p "$FAKE_BIN"
: > "$FAKE_LOG"
PATH="$FAKE_BIN:$PATH"
export FAKE_BIN FAKE_LOG PATH

# Source all modules in production order. lib/core/bootstrap.sh installs its
# own EXIT trap. In the test shell, restore the bats trap (bats reports
# results from it); in a subshell, clear it (`trap -p` shows the parent's
# traps there, and re-installing them would report the test twice).
load_modules() {
    local saved_exit_trap
    saved_exit_trap=$(trap -p EXIT)
    # shellcheck disable=SC2034 # read by _source_all_modules
    SCRIPT_DIR="$PROJECT_ROOT"
    # shellcheck source=lib/core/bootstrap.sh
    . "$PROJECT_ROOT/lib/core/bootstrap.sh"
    _source_all_modules
    if [ "${BASH_SUBSHELL:-0}" -eq 0 ] && [ -n "$saved_exit_trap" ]; then
        eval "$saved_exit_trap"
    else
        trap - EXIT
    fi
}

# Silence log output from modules (errors included).
quiet_logs() {
    log_error() { :; }
    log_warn() { :; }
    log_info() { :; }
    log_debug() { :; }
}

# Create a fake command that records its arguments and optionally prints
# output and exits with a given status.
# Usage: fake_cmd <name> [exit_code] [stdout]
fake_cmd() {
    local name="$1" rc="${2:-0}" out="${3:-}"
    {
        printf '#!/bin/sh\n'
        printf 'printf "%%s\\n" "%s $*" >> "%s"\n' "$name" "$FAKE_LOG"
        if [ -n "$out" ]; then
            printf "cat <<'FAKE_EOF'\n%s\nFAKE_EOF\n" "$out"
        fi
        printf 'exit %s\n' "$rc"
    } > "$FAKE_BIN/$name"
    chmod +x "$FAKE_BIN/$name"
}

fake_calls() {
    cat "$FAKE_LOG"
}

_assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$desc" "$expected" "$actual" >&2
        return 1
    fi
}

_assert_ne() {
    local desc="$1" not_expected="$2" actual="$3"
    if [ "$not_expected" = "$actual" ]; then
        printf 'FAIL: %s\n  should not be: %s\n' "$desc" "$not_expected" >&2
        return 1
    fi
}

_assert_exit_code() {
    local desc="$1" expected_code="$2"
    shift 2
    local actual_code=0
    "$@" >/dev/null 2>&1 || actual_code=$?
    if [ "$expected_code" -ne "$actual_code" ]; then
        printf 'FAIL: %s\n  expected exit: %s\n  actual exit:   %s\n' "$desc" "$expected_code" "$actual_code" >&2
        return 1
    fi
}
