#!/usr/bin/env bats
# Ported from test/unit/test_bootstrap.sh

setup() {
    load '../helpers/common'
}

# ============================================================
# Test: _csv_count
# ============================================================
_case_csv_count() {
    echo "=== Test: _csv_count ==="
    (
        load_modules

        _assert_eq "csv_count empty" "0" "$(_csv_count "")"
        _assert_eq "csv_count single" "1" "$(_csv_count "10.0.0.1")"
        _assert_eq "csv_count two" "2" "$(_csv_count "10.0.0.1,10.0.0.2")"
        _assert_eq "csv_count three" "3" "$(_csv_count "10.0.0.1,10.0.0.2,10.0.0.3")"
        _assert_eq "csv_count with user@" "2" "$(_csv_count "root@10.0.0.1,admin@10.0.0.2")"
    )
}

# ============================================================
# Test: _csv_get
# ============================================================
_case_csv_get() {
    echo "=== Test: _csv_get ==="
    (
        load_modules

        local list="a,b,c"
        _assert_eq "csv_get index 0" "a" "$(_csv_get "$list" 0)"
        _assert_eq "csv_get index 1" "b" "$(_csv_get "$list" 1)"
        _assert_eq "csv_get index 2" "c" "$(_csv_get "$list" 2)"

        local ips="10.0.0.1,10.0.0.2,10.0.0.3"
        _assert_eq "csv_get ip index 0" "10.0.0.1" "$(_csv_get "$ips" 0)"
        _assert_eq "csv_get ip index 2" "10.0.0.3" "$(_csv_get "$ips" 2)"
    )
}

# ============================================================
# Test: _append_passthrough_to_cmd
# ============================================================
_case_append_passthrough_to_cmd() {
    echo "=== Test: _append_passthrough_to_cmd ==="
    (
        load_modules
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }

        # Empty args
        local result
        result=$(_append_passthrough_to_cmd "mycmd" "")
        _assert_eq "passthrough empty" "mycmd" "$result"

        # Single arg
        result=$(_append_passthrough_to_cmd "mycmd" "--verbose")
        local has_verbose="false"
        echo "$result" | grep -q "verbose" && has_verbose="true"
        _assert_eq "passthrough single" "true" "$has_verbose"

        # Multiple args (newline-separated)
        local args="--distro
debian"
        result=$(_append_passthrough_to_cmd "mycmd" "$args")
        local has_distro="false"
        echo "$result" | grep -q "distro" && has_distro="true"
        _assert_eq "passthrough multi" "true" "$has_distro"
    )
}

# ============================================================
# Test: _append_passthrough_to_cmd_worker filters HA flags
# ============================================================
_case_append_passthrough_filtered() {
    echo "=== Test: _append_passthrough_filtered filters specified flags ==="
    (
        load_modules
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }

        # HA-specific flags should be filtered out
        local args="--ha-vip
10.0.0.100
--verbose"
        local result
        result=$(_append_passthrough_filtered "mycmd" "$args" "--ha-vip --ha-interface")

        local has_vip="false"
        echo "$result" | grep -q "ha-vip" && has_vip="true"
        _assert_eq "filtered passthrough filters --ha-vip" "false" "$has_vip"

        local has_verbose="false"
        echo "$result" | grep -q "verbose" && has_verbose="true"
        _assert_eq "filtered passthrough keeps --verbose" "true" "$has_verbose"
    )
}

# ============================================================
# Test: _posix_shell_quote
# ============================================================
_case_posix_shell_quote() {
    echo "=== Test: _posix_shell_quote ==="
    (
        load_modules

        local result
        result=$(_posix_shell_quote "simple")
        local has_simple="false"
        echo "$result" | grep -q "simple" && has_simple="true"
        _assert_eq "quote simple string" "true" "$has_simple"

        result=$(_posix_shell_quote "it's quoted")
        local has_escaped="false"
        echo "$result" | grep -q "it" && has_escaped="true"
        _assert_eq "quote string with apostrophe" "true" "$has_escaped"
    )
}

# ============================================================
# Test: _posix_shell_quote precise output
# ============================================================
_case_posix_shell_quote_precise() {
    echo "=== Test: _posix_shell_quote precise output ==="
    (
        load_modules

        # Simple string should be single-quoted (function appends trailing space)
        local result
        result=$(_posix_shell_quote "hello")
        _assert_eq "quote simple" "'hello' " "$result"

        # String with space
        result=$(_posix_shell_quote "hello world")
        _assert_eq "quote space" "'hello world' " "$result"

        # String with single quote: escaped as '\''
        result=$(_posix_shell_quote "it's")
        _assert_eq "quote apostrophe" "'it'\''s' " "$result"

        # Empty string
        result=$(_posix_shell_quote "")
        _assert_eq "quote empty" "'' " "$result"
    )
}

# ============================================================
# Test: _append_passthrough_to_cmd special chars
# ============================================================
_case_passthrough_special_chars() {
    echo "=== Test: _append_passthrough_to_cmd special characters ==="
    (
        load_modules
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }

        # Arg with spaces
        local args="--config
/path/with spaces/file.yaml"
        local result
        result=$(_append_passthrough_to_cmd "cmd" "$args")
        local has_config="false"
        echo "$result" | grep -q "config" && has_config="true"
        _assert_eq "passthrough special: has config" "true" "$has_config"
        local has_quoted_path="false"
        echo "$result" | grep -q "spaces" && has_quoted_path="true"
        _assert_eq "passthrough special: path preserved" "true" "$has_quoted_path"
    )
}

# ============================================================
# Test: _append_passthrough_to_cmd_worker HA flag filtering (deep)
# ============================================================
_case_passthrough_filtered_ha_interface() {
    echo "=== Test: _append_passthrough_filtered filters --ha-interface ==="
    (
        load_modules
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }

        local args="--ha-interface
eth0
--ha-vip
10.0.0.100
--version
1.30.0"
        local result
        result=$(_append_passthrough_filtered "mycmd" "$args" "--ha-vip --ha-interface")

        local has_interface="false"
        echo "$result" | grep -q "ha-interface" && has_interface="true"
        _assert_eq "filtered filters --ha-interface" "false" "$has_interface"

        local has_vip="false"
        echo "$result" | grep -q "ha-vip" && has_vip="true"
        _assert_eq "filtered filters --ha-vip" "false" "$has_vip"

        local has_version="false"
        echo "$result" | grep -q "version" && has_version="true"
        _assert_eq "filtered keeps --version" "true" "$has_version"

        local has_1_30="false"
        echo "$result" | grep -q "1.30.0" && has_1_30="true"
        _assert_eq "filtered keeps version value" "true" "$has_1_30"
    )
}

# ============================================================
# Test: cleanup handler stack
# ============================================================
_case_cleanup_handlers() {
    echo "=== Test: cleanup handler stack ==="
    (
        load_modules

        # Test push and pop
        _EXIT_CLEANUP_HANDLERS=""
        _push_cleanup "handler_a"
        _push_cleanup "handler_b"

        local has_a="false"
        echo "$_EXIT_CLEANUP_HANDLERS" | grep -q "handler_a" && has_a="true"
        _assert_eq "push_cleanup adds handler_a" "true" "$has_a"

        local has_b="false"
        echo "$_EXIT_CLEANUP_HANDLERS" | grep -q "handler_b" && has_b="true"
        _assert_eq "push_cleanup adds handler_b" "true" "$has_b"

        _pop_cleanup
        local still_has_b="false"
        echo "$_EXIT_CLEANUP_HANDLERS" | grep -q "handler_b" && still_has_b="true"
        _assert_eq "pop_cleanup removes handler_b" "false" "$still_has_b"

        local still_has_a="false"
        echo "$_EXIT_CLEANUP_HANDLERS" | grep -q "handler_a" && still_has_a="true"
        _assert_eq "pop_cleanup keeps handler_a" "true" "$still_has_a"
    )
}

# ============================================================
# Test: CSV helpers edge cases
# ============================================================
_case_csv_edge_cases() {
    echo "=== Test: CSV helpers edge cases ==="
    (
        load_modules

        # Trailing comma
        _assert_eq "trailing comma count" "2" "$(_csv_count "a,b,")"

        # Single item with user@
        _assert_eq "user@host count" "1" "$(_csv_count "admin@10.0.0.1")"

        # Get from single-item list
        _assert_eq "csv_get single item" "only" "$(_csv_get "only" 0)"
    )
}

# ============================================================
# Test: _csv_any
# ============================================================
_case_csv_any() {
    echo "=== Test: _csv_any ==="
    (
        load_modules

        _is_even_digit() { case "$1" in 2|4|6|8|0) return 0 ;; *) return 1 ;; esac; }

        # Match found
        local result=0
        _csv_any "1,3,4,7" _is_even_digit || result=$?
        _assert_eq "csv_any match found" "0" "$result"

        # No match
        result=0
        _csv_any "1,3,5,7" _is_even_digit || result=$?
        _assert_eq "csv_any no match" "1" "$result"

        # Empty string
        result=0
        _csv_any "" _is_even_digit || result=$?
        _assert_eq "csv_any empty" "1" "$result"

        # Single match
        result=0
        _csv_any "2" _is_even_digit || result=$?
        _assert_eq "csv_any single match" "0" "$result"

        # Whitespace trimming
        result=0
        _csv_any " 1 , 3 , 6 " _is_even_digit || result=$?
        _assert_eq "csv_any whitespace trim" "0" "$result"
    )
}

@test "_csv_count" {
    _case_csv_count
}

@test "_csv_get" {
    _case_csv_get
}

@test "_append_passthrough_to_cmd" {
    _case_append_passthrough_to_cmd
}

@test "_append_passthrough_filtered filters specified flags" {
    _case_append_passthrough_filtered
}

@test "_posix_shell_quote" {
    _case_posix_shell_quote
}

@test "cleanup handler stack" {
    _case_cleanup_handlers
}

@test "_csv_any" {
    _case_csv_any
}

@test "_posix_shell_quote precise output" {
    _case_posix_shell_quote_precise
}

@test "_append_passthrough_to_cmd special characters" {
    _case_passthrough_special_chars
}

@test "_append_passthrough_filtered filters --ha-interface" {
    _case_passthrough_filtered_ha_interface
}

@test "CSV helpers edge cases" {
    _case_csv_edge_cases
}
