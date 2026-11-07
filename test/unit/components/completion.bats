#!/usr/bin/env bats
# Ported from test/unit/test_completion.sh

setup() {
    load '../helpers/common'
}

# File-local module loader
_load_completion_test_modules() {
    load_modules
    log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
}

