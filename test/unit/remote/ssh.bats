#!/usr/bin/env bats
# Ported from test/unit/test_ssh.sh

setup() {
    load '../helpers/common'
}

# File-local module loaders (avoids repeating source blocks in every test)
_load_ssh_test_modules() {
    load_modules
}

_load_ssh_full_test_modules() {
    _load_ssh_test_modules
}

_load_ssh_stub_modules() {
    load_modules
    log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
}

# ============================================================
# Test: _parse_node_address parsing
# ============================================================
_case_parse_node_address() {
    echo "=== Test: _parse_node_address ==="
    (
        _load_ssh_test_modules

        # user@host format
        _parse_node_address "admin@10.0.0.1"
        _assert_eq "user@host: user" "admin" "$_NODE_USER"
        _assert_eq "user@host: host" "10.0.0.1" "$_NODE_HOST"

        # bare host format (should use DEPLOY_SSH_USER)
        DEPLOY_SSH_USER="root"
        _parse_node_address "10.0.0.2"
        _assert_eq "bare host: user" "root" "$_NODE_USER"
        _assert_eq "bare host: host" "10.0.0.2" "$_NODE_HOST"

        # IPv6 bracketed format
        DEPLOY_SSH_USER="admin"
        _parse_node_address "[fd00::1]"
        _assert_eq "IPv6 bare: user" "admin" "$_NODE_USER"
        _assert_eq "IPv6 bare: host" "[fd00::1]" "$_NODE_HOST"

        # user@IPv6 format
        _parse_node_address "root@[fd00::2]"
        _assert_eq "user@IPv6: user" "root" "$_NODE_USER"
        _assert_eq "user@IPv6: host" "[fd00::2]" "$_NODE_HOST"
    )
}

# ============================================================
# Test: _build_deploy_ssh_opts
# ============================================================
_case_build_deploy_ssh_opts() {
    echo "=== Test: _build_deploy_ssh_opts ==="
    (
        _load_ssh_test_modules

        # Default: no password, no key
        DEPLOY_SSH_PASSWORD=""
        DEPLOY_SSH_KEY=""
        DEPLOY_SSH_PORT="22"
        DEPLOY_SSH_HOST_KEY_CHECK="yes"
        _DEPLOY_KNOWN_HOSTS="/tmp/test-kh"
        SSH_AUTH_SOCK=""
        _build_deploy_ssh_opts

        local has_batchmode="false"
        if echo "$_SSH_OPTS" | grep -q 'BatchMode=yes'; then has_batchmode="true"; fi
        _assert_eq "BatchMode present without password" "true" "$has_batchmode"

        local has_strict="false"
        if echo "$_SSH_OPTS" | grep -q 'StrictHostKeyChecking=yes'; then has_strict="true"; fi
        _assert_eq "StrictHostKeyChecking=yes" "true" "$has_strict"

        local has_port="false"
        if echo "$_SSH_OPTS" | grep -q '\-p 22'; then has_port="true"; fi
        _assert_eq "port 22 in opts" "true" "$has_port"

        # With password: no BatchMode
        DEPLOY_SSH_PASSWORD="secret"
        _build_deploy_ssh_opts
        has_batchmode="false"
        if echo "$_SSH_OPTS" | grep -q 'BatchMode=yes'; then has_batchmode="true"; fi
        _assert_eq "BatchMode absent with password" "false" "$has_batchmode"

        # With key: key option present
        DEPLOY_SSH_PASSWORD=""
        DEPLOY_SSH_KEY="/tmp/test-key"
        _build_deploy_ssh_opts
        local has_key="false"
        if echo "$_SSH_OPTS" | grep -q '\-i /tmp/test-key'; then has_key="true"; fi
        _assert_eq "key option present" "true" "$has_key"

        # With SSH agent: no BatchMode (unless explicit key)
        DEPLOY_SSH_PASSWORD=""
        DEPLOY_SSH_KEY=""
        SSH_AUTH_SOCK="/tmp/agent.sock"
        _build_deploy_ssh_opts
        has_batchmode="false"
        if echo "$_SSH_OPTS" | grep -q 'BatchMode=yes'; then has_batchmode="true"; fi
        _assert_eq "BatchMode absent with SSH agent" "false" "$has_batchmode"

        # With SSH agent + explicit key: BatchMode present
        DEPLOY_SSH_KEY="/tmp/test-key"
        _build_deploy_ssh_opts
        has_batchmode="false"
        if echo "$_SSH_OPTS" | grep -q 'BatchMode=yes'; then has_batchmode="true"; fi
        _assert_eq "BatchMode present with agent+key" "true" "$has_batchmode"
    )
}

# ============================================================
# Test: _setup_session_known_hosts / _teardown_session_known_hosts
# ============================================================
_case_session_known_hosts() {
    echo "=== Test: _setup_session_known_hosts / _teardown ==="
    (
        _load_ssh_full_test_modules

        DEPLOY_SSH_KNOWN_HOSTS_FILE=""

        # Setup creates a temp file
        _setup_session_known_hosts "test"
        _assert_ne "known_hosts file created" "" "$_DEPLOY_KNOWN_HOSTS"
        local kh_path="$_DEPLOY_KNOWN_HOSTS"
        local exists="false"
        if [ -f "$kh_path" ]; then exists="true"; fi
        _assert_eq "known_hosts file exists" "true" "$exists"

        # Teardown removes it
        _teardown_session_known_hosts
        exists="true"
        if [ ! -f "$kh_path" ]; then exists="false"; fi
        _assert_eq "known_hosts file removed" "false" "$exists"
        _assert_eq "known_hosts var cleared" "" "$_DEPLOY_KNOWN_HOSTS"

        # Setup with seed file
        local seed_file
        seed_file=$(mktemp /tmp/test-seed-kh-XXXXXX)
        echo "testhost ssh-rsa AAAA..." > "$seed_file"
        DEPLOY_SSH_KNOWN_HOSTS_FILE="$seed_file"
        _setup_session_known_hosts "test"
        local content
        content=$(cat "$_DEPLOY_KNOWN_HOSTS")
        local has_seed="false"
        if echo "$content" | grep -q 'testhost'; then has_seed="true"; fi
        _assert_eq "known_hosts seeded from file" "true" "$has_seed"
        _teardown_session_known_hosts
        rm -f "$seed_file"
    )
}

# ============================================================
# Test: _bundle_dir_set / _bundle_dir_lookup
# ============================================================
_case_bundle_dir_store() {
    echo "=== Test: _bundle_dir_set / _bundle_dir_lookup ==="
    (
        _load_ssh_test_modules

        _DEPLOY_NODE_BUNDLE_DIRS=""
        _bundle_dir_set "10.0.0.1" "/tmp/dir1"
        _bundle_dir_set "10.0.0.2" "/tmp/dir2"
        _bundle_dir_set "[fd00::1]" "/tmp/dir3"

        _assert_eq "lookup host1" "/tmp/dir1" "$(_bundle_dir_lookup "10.0.0.1")"
        _assert_eq "lookup host2" "/tmp/dir2" "$(_bundle_dir_lookup "10.0.0.2")"
        _assert_eq "lookup IPv6" "/tmp/dir3" "$(_bundle_dir_lookup "[fd00::1]")"
        _assert_eq "lookup missing" "" "$(_bundle_dir_lookup "10.0.0.99")"
    )
}

# ============================================================
# Test: _validate_ssh_key_permissions
# ============================================================
_case_validate_ssh_key_permissions() {
    echo "=== Test: _validate_ssh_key_permissions ==="
    (
        _load_ssh_full_test_modules

        # No key: should pass silently
        DEPLOY_SSH_KEY=""
        local out
        out=$(_validate_ssh_key_permissions 2>&1)
        _assert_eq "no key passes silently" "" "$out"

        # Key with 600: no warning
        local tmpkey
        tmpkey=$(mktemp /tmp/test-sshkey-XXXXXX)
        chmod 600 "$tmpkey"
        DEPLOY_SSH_KEY="$tmpkey"
        out=$(_validate_ssh_key_permissions 2>&1)
        local has_warn="false"
        if echo "$out" | grep -q 'WARN'; then has_warn="true"; fi
        _assert_eq "600 key no warning" "false" "$has_warn"

        # Key with 644: should warn
        chmod 644 "$tmpkey"
        out=$(_validate_ssh_key_permissions 2>&1)
        has_warn="false"
        if echo "$out" | grep -q 'permissions 644'; then has_warn="true"; fi
        _assert_eq "644 key warns" "true" "$has_warn"

        rm -f "$tmpkey"
    )
}

# ============================================================
# Test: _load_ssh_password_file
# ============================================================
_case_load_ssh_password_file() {
    echo "=== Test: _load_ssh_password_file ==="
    (
        _load_ssh_full_test_modules

        # Non-existent file should fail
        local exit_code=0
        (_load_ssh_password_file "/tmp/nonexistent-pw-file") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "missing file rejected" "0" "$exit_code"

        # File with bad permissions should fail
        local tmpfile
        tmpfile=$(mktemp /tmp/test-sshpw-XXXXXX)
        echo "testpassword" > "$tmpfile"
        chmod 644 "$tmpfile"
        exit_code=0
        (_load_ssh_password_file "$tmpfile") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "644 permissions rejected" "0" "$exit_code"

        # File with 600 and content should succeed
        chmod 600 "$tmpfile"
        DEPLOY_SSH_PASSWORD=""
        _load_ssh_password_file "$tmpfile"
        _assert_eq "password loaded" "testpassword" "$DEPLOY_SSH_PASSWORD"

        # Empty file should fail
        : > "$tmpfile"
        chmod 600 "$tmpfile"
        DEPLOY_SSH_PASSWORD=""
        exit_code=0
        (_load_ssh_password_file "$tmpfile") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "empty file rejected" "0" "$exit_code"

        rm -f "$tmpfile"
    )
}

# ============================================================
# Test: --remote-timeout / --poll-interval parsing and validation
# ============================================================
_case_timeout_cli_options() {
    echo "=== Test: --remote-timeout / --poll-interval parsing ==="
    (
        _load_ssh_test_modules

        # Valid --remote-timeout
        _parse_common_ssh_args 2 "--remote-timeout" "300"
        _assert_eq "--remote-timeout parsed" "300" "$DEPLOY_REMOTE_TIMEOUT"
        _assert_eq "--remote-timeout shift" "2" "$_SSH_SHIFT"

        # Valid --poll-interval
        _parse_common_ssh_args 2 "--poll-interval" "5"
        _assert_eq "--poll-interval parsed" "5" "$DEPLOY_POLL_INTERVAL"
        _assert_eq "--poll-interval shift" "2" "$_SSH_SHIFT"

        # Invalid --remote-timeout (non-numeric)
        local exit_code=0
        (_parse_common_ssh_args 2 "--remote-timeout" "abc") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "non-numeric timeout rejected" "0" "$exit_code"

        # Invalid --poll-interval (zero)
        exit_code=0
        (_parse_common_ssh_args 2 "--poll-interval" "0") >/dev/null 2>&1 || exit_code=$?
        _assert_ne "zero poll-interval rejected" "0" "$exit_code"

        # Non-SSH option returns 1
        _parse_common_ssh_args 2 "--something-else" "val" || exit_code=$?
        _assert_ne "non-ssh option returns 1" "0" "$exit_code"
    )
}

# ============================================================
# Test: _build_deploy_ssh_opts with key only (deep)
# ============================================================
_case_build_ssh_opts_key_only() {
    echo "=== Test: _build_deploy_ssh_opts with key only ==="
    (
        _load_ssh_stub_modules

        DEPLOY_SSH_KEY="/path/to/key"
        DEPLOY_SSH_PASSWORD=""
        DEPLOY_SSH_PORT=22
        DEPLOY_SSH_HOST_KEY_CHECK="yes"
        _DEPLOY_KNOWN_HOSTS="/dev/null"
        SSH_AUTH_SOCK=""

        _build_deploy_ssh_opts

        local has_batch="false"
        echo "$_SSH_OPTS" | grep -q "BatchMode=yes" && has_batch="true"
        _assert_eq "key-only: BatchMode=yes" "true" "$has_batch"

        local has_key="false"
        echo "$_SSH_OPTS" | grep -q "\-i /path/to/key" && has_key="true"
        _assert_eq "key-only: -i present" "true" "$has_key"

        local has_port="false"
        echo "$_SSH_OPTS" | grep -q "\-p 22" && has_port="true"
        _assert_eq "key-only: -p 22" "true" "$has_port"
    )
}

_case_build_ssh_opts_password() {
    echo "=== Test: _build_deploy_ssh_opts with password ==="
    (
        _load_ssh_stub_modules

        DEPLOY_SSH_KEY=""
        DEPLOY_SSH_PASSWORD="secret"
        DEPLOY_SSH_PORT=2222
        DEPLOY_SSH_HOST_KEY_CHECK="no"
        _DEPLOY_KNOWN_HOSTS="/tmp/test-kh"
        SSH_AUTH_SOCK=""

        _build_deploy_ssh_opts

        local has_batch="false"
        echo "$_SSH_OPTS" | grep -q "BatchMode" && has_batch="true"
        _assert_eq "password: no BatchMode" "false" "$has_batch"

        local has_port="false"
        echo "$_SSH_OPTS" | grep -q "\-p 2222" && has_port="true"
        _assert_eq "password: port 2222" "true" "$has_port"

        local has_strict_no="false"
        echo "$_SSH_OPTS" | grep -q "StrictHostKeyChecking=no" && has_strict_no="true"
        _assert_eq "password: StrictHostKeyChecking=no" "true" "$has_strict_no"

        local has_no_key="true"
        echo "$_SSH_OPTS" | grep -q "\-i " && has_no_key="false"
        _assert_eq "password: no -i flag" "true" "$has_no_key"
    )
}

_case_build_ssh_opts_ssh_agent() {
    echo "=== Test: _build_deploy_ssh_opts with SSH agent ==="
    (
        _load_ssh_stub_modules

        DEPLOY_SSH_KEY=""
        DEPLOY_SSH_PASSWORD=""
        DEPLOY_SSH_PORT=22
        DEPLOY_SSH_HOST_KEY_CHECK="yes"
        _DEPLOY_KNOWN_HOSTS="/dev/null"
        SSH_AUTH_SOCK="/tmp/agent.sock"

        _build_deploy_ssh_opts

        # With SSH agent and no key, BatchMode should be skipped
        local has_batch="false"
        echo "$_SSH_OPTS" | grep -q "BatchMode" && has_batch="true"
        _assert_eq "agent: no BatchMode (agent-forwarded)" "false" "$has_batch"
    )
}

_case_build_ssh_opts_agent_with_key() {
    echo "=== Test: _build_deploy_ssh_opts with SSH agent + explicit key ==="
    (
        _load_ssh_stub_modules

        DEPLOY_SSH_KEY="/path/to/explicit-key"
        DEPLOY_SSH_PASSWORD=""
        DEPLOY_SSH_PORT=22
        DEPLOY_SSH_HOST_KEY_CHECK="yes"
        _DEPLOY_KNOWN_HOSTS="/dev/null"
        SSH_AUTH_SOCK="/tmp/agent.sock"

        _build_deploy_ssh_opts

        # Agent present BUT explicit key -> BatchMode should be ON
        local has_batch="false"
        echo "$_SSH_OPTS" | grep -q "BatchMode=yes" && has_batch="true"
        _assert_eq "agent+key: BatchMode=yes" "true" "$has_batch"
    )
}

# ============================================================
# Test: _parse_node_address bare host (deep)
# ============================================================
_case_parse_node_address_bare_host() {
    echo "=== Test: _parse_node_address bare host ==="
    (
        _load_ssh_stub_modules

        DEPLOY_SSH_USER="root"
        _parse_node_address "10.0.0.1"
        _assert_eq "bare host: user" "root" "$_NODE_USER"
        _assert_eq "bare host: host" "10.0.0.1" "$_NODE_HOST"
    )
}

_case_parse_node_address_user_at_host() {
    echo "=== Test: _parse_node_address user@host ==="
    (
        _load_ssh_stub_modules

        DEPLOY_SSH_USER="root"
        _parse_node_address "admin@192.168.1.10"
        _assert_eq "user@host: user" "admin" "$_NODE_USER"
        _assert_eq "user@host: host" "192.168.1.10" "$_NODE_HOST"
    )
}

_case_parse_node_address_ipv6_bracketed() {
    echo "=== Test: _parse_node_address IPv6 bracketed ==="
    (
        _load_ssh_stub_modules

        DEPLOY_SSH_USER="root"
        _parse_node_address "user@[::1]"
        _assert_eq "IPv6: user" "user" "$_NODE_USER"
        _assert_eq "IPv6: host" "[::1]" "$_NODE_HOST"
    )
}

_case_parse_node_address_bare_ipv6() {
    echo "=== Test: _parse_node_address bare IPv6 ==="
    (
        _load_ssh_stub_modules

        DEPLOY_SSH_USER="root"
        # Bare IPv6 without @ should use default user
        _parse_node_address "[fd00::1]"
        _assert_eq "bare IPv6: user" "root" "$_NODE_USER"
        _assert_eq "bare IPv6: host" "[fd00::1]" "$_NODE_HOST"
    )
}

# ============================================================
# Test: _bundle_dir_set / _bundle_dir_lookup (deep)
# ============================================================
_case_bundle_dir_store_deep() {
    echo "=== Test: _bundle_dir_set / _bundle_dir_lookup (deep) ==="
    (
        _load_ssh_stub_modules
        load_modules

        _DEPLOY_NODE_BUNDLE_DIRS=""
        _bundle_dir_set "10.0.0.1" "/tmp/dir1"
        _bundle_dir_set "10.0.0.2" "/tmp/dir2"
        _bundle_dir_set "10.0.0.3" "/tmp/dir3"

        _assert_eq "lookup host 1" "/tmp/dir1" "$(_bundle_dir_lookup "10.0.0.1")"
        _assert_eq "lookup host 2" "/tmp/dir2" "$(_bundle_dir_lookup "10.0.0.2")"
        _assert_eq "lookup host 3" "/tmp/dir3" "$(_bundle_dir_lookup "10.0.0.3")"
        _assert_eq "lookup missing host" "" "$(_bundle_dir_lookup "10.0.0.99")"
    )
}

# ============================================================
# Test: _setup_session_known_hosts / _teardown lifecycle (deep)
# ============================================================
_case_session_known_hosts_lifecycle() {
    echo "=== Test: _setup_session_known_hosts / _teardown lifecycle ==="
    (
        load_modules
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }

        DEPLOY_SSH_KNOWN_HOSTS_FILE=""
        DEPLOY_PERSIST_KNOWN_HOSTS=""

        _setup_session_known_hosts "test"
        local kh_file="$_DEPLOY_KNOWN_HOSTS"

        # File should exist
        local exists="false"
        [ -f "$kh_file" ] && exists="true"
        _assert_eq "known_hosts file created" "true" "$exists"

        # Permissions should be 600
        local perms
        perms=$(stat -c '%a' "$kh_file" 2>/dev/null || stat -f '%Lp' "$kh_file" 2>/dev/null) || true
        _assert_eq "known_hosts permissions 600" "600" "$perms"

        _teardown_session_known_hosts

        # File should be removed
        local still_exists="false"
        [ -f "$kh_file" ] && still_exists="true"
        _assert_eq "known_hosts file removed" "false" "$still_exists"

        # Global should be cleared
        _assert_eq "known_hosts var cleared" "" "$_DEPLOY_KNOWN_HOSTS"
    )
}

_case_session_known_hosts_seeded() {
    echo "=== Test: _setup_session_known_hosts with seed file ==="
    (
        load_modules
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }

        local seed_file
        seed_file=$(mktemp /tmp/test-seed-kh-XXXXXX)
        echo "known.host ssh-rsa AAAAB3..." > "$seed_file"

        # shellcheck disable=SC2034 # used by _setup_session_known_hosts
        DEPLOY_SSH_KNOWN_HOSTS_FILE="$seed_file"
        # shellcheck disable=SC2034 # used by _teardown_session_known_hosts
        DEPLOY_PERSIST_KNOWN_HOSTS=""

        _setup_session_known_hosts "test"

        local content
        content=$(cat "$_DEPLOY_KNOWN_HOSTS")
        local has_seed="false"
        echo "$content" | grep -q "known.host" && has_seed="true"
        _assert_eq "seeded known_hosts has content" "true" "$has_seed"

        _teardown_session_known_hosts
        rm -f "$seed_file"
    )
}

# ============================================================
# Test: SSH key permission validation (deep)
# ============================================================
_case_ssh_key_permission_validation() {
    echo "=== Test: _validate_ssh_key_permissions ==="
    (
        load_modules
        local captured_warn=""
        log_error() { :; }; log_info() { :; }; log_debug() { :; }
        log_warn() { captured_warn="$*"; }

        local tmpkey
        tmpkey=$(mktemp /tmp/test-key-XXXXXX)

        # Good permissions: 600
        chmod 600 "$tmpkey"
        DEPLOY_SSH_KEY="$tmpkey"
        captured_warn=""
        _validate_ssh_key_permissions
        _assert_eq "600: no warning" "" "$captured_warn"

        # Good permissions: 400
        chmod 400 "$tmpkey"
        captured_warn=""
        _validate_ssh_key_permissions
        _assert_eq "400: no warning" "" "$captured_warn"

        # Bad permissions: 644
        chmod 644 "$tmpkey"
        captured_warn=""
        _validate_ssh_key_permissions
        local has_warn="false"
        echo "$captured_warn" | grep -q "permissions" && has_warn="true"
        _assert_eq "644: warns about permissions" "true" "$has_warn"

        rm -f "$tmpkey"
    )
}

# ============================================================
# Test: SSH password file loading (deep)
# ============================================================
_case_ssh_password_file_loading() {
    echo "=== Test: _load_ssh_password_file ==="
    (
        load_modules
        local captured_error=""
        log_error() { captured_error="$*"; }
        log_warn() { :; }; log_info() { :; }; log_debug() { :; }

        local tmpfile
        tmpfile=$(mktemp /tmp/test-pwfile-XXXXXX)

        # Good: correct permissions and content
        echo "mysecretpassword" > "$tmpfile"
        chmod 600 "$tmpfile"
        DEPLOY_SSH_PASSWORD=""
        _load_ssh_password_file "$tmpfile"
        _assert_eq "password loaded" "mysecretpassword" "$DEPLOY_SSH_PASSWORD"

        # Bad: wrong permissions
        chmod 644 "$tmpfile"
        DEPLOY_SSH_PASSWORD=""
        captured_error=""
        local rc=0
        _load_ssh_password_file "$tmpfile" || rc=$?
        _assert_ne "644 rejected" "0" "$rc"
        local has_perm_err="false"
        echo "$captured_error" | grep -q "permissions" && has_perm_err="true"
        _assert_eq "reports permission error" "true" "$has_perm_err"

        # Bad: empty file
        chmod 600 "$tmpfile"
        : > "$tmpfile"
        captured_error=""
        rc=0
        _load_ssh_password_file "$tmpfile" || rc=$?
        _assert_ne "empty file rejected" "0" "$rc"
        local has_empty_err="false"
        echo "$captured_error" | grep -q "empty" && has_empty_err="true"
        _assert_eq "reports empty error" "true" "$has_empty_err"

        # Bad: file not found
        captured_error=""
        rc=0
        _load_ssh_password_file "/nonexistent/path" || rc=$?
        _assert_ne "nonexistent rejected" "0" "$rc"

        rm -f "$tmpfile"
    )
}

# ============================================================
# Test: _persist_known_hosts
# ============================================================
_case_persist_known_hosts() {
    echo "=== Test: _persist_known_hosts ==="
    (
        load_modules
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }

        # Create a session known_hosts with content
        _DEPLOY_KNOWN_HOSTS=$(mktemp /tmp/test-kh-XXXXXX)
        echo "host1 ssh-rsa KEY1" > "$_DEPLOY_KNOWN_HOSTS"

        local dest
        dest=$(mktemp /tmp/test-persist-XXXXXX)
        _persist_known_hosts "$dest"

        # Content should be copied
        local content
        content=$(cat "$dest")
        local has_key="false"
        echo "$content" | grep -q "host1 ssh-rsa KEY1" && has_key="true"
        _assert_eq "persisted content correct" "true" "$has_key"

        # Permissions should be 600
        local perms
        perms=$(stat -c '%a' "$dest" 2>/dev/null || stat -f '%Lp' "$dest" 2>/dev/null) || true
        _assert_eq "persisted file permissions" "600" "$perms"

        rm -f "$_DEPLOY_KNOWN_HOSTS" "$dest"
    )
}

# ============================================================
# Test: _build_scp_args IPv6 bracketing
# ============================================================
_case_build_scp_args_ipv6() {
    echo "=== Test: _build_scp_args IPv6 bracketing ==="
    (
        _load_ssh_stub_modules

        DEPLOY_SSH_KEY=""
        DEPLOY_SSH_PASSWORD=""
        DEPLOY_SSH_PORT=22
        # shellcheck disable=SC2034 # used by _build_deploy_ssh_opts
        DEPLOY_SSH_HOST_KEY_CHECK="yes"
        _DEPLOY_KNOWN_HOSTS="/dev/null"
        # shellcheck disable=SC2034 # used by _build_deploy_ssh_opts
        SSH_AUTH_SOCK=""

        # Regular IPv4: no brackets needed
        _build_scp_args "10.0.0.1"
        _assert_eq "IPv4 host unchanged" "10.0.0.1" "$_SCP_HOST"

        # Bare IPv6: needs brackets
        _build_scp_args "::1"
        _assert_eq "bare IPv6 bracketed" "[::1]" "$_SCP_HOST"

        # Already bracketed IPv6
        _build_scp_args "[::1]"
        _assert_eq "bracketed IPv6 unchanged" "[::1]" "$_SCP_HOST"

        # Full IPv6 address
        _build_scp_args "fd00:1::2"
        _assert_eq "full IPv6 bracketed" "[fd00:1::2]" "$_SCP_HOST"

        # SCP opts should have -P instead of -p
        local has_P="false"
        echo "$_SCP_OPTS" | grep -q "\-P " && has_P="true"
        _assert_eq "SCP uses -P for port" "true" "$has_P"

        local has_lowercase_p="true"
        echo "$_SCP_OPTS" | grep -q " -p " && has_lowercase_p="true" || has_lowercase_p="false"
        _assert_eq "SCP no -p (lowercase)" "false" "$has_lowercase_p"
    )
}

# ============================================================
# Test: _log_ssh_settings output
# ============================================================
_case_log_ssh_settings() {
    echo "=== Test: _log_ssh_settings output ==="
    (
        load_modules
        local captured_lines=""
        log_error() { :; }; log_warn() { :; }; log_debug() { :; }
        log_info() { captured_lines="${captured_lines}${captured_lines:+
}$*"; }

        # shellcheck disable=SC2034 # used by _log_ssh_settings
        DEPLOY_SSH_USER="admin"
        # shellcheck disable=SC2034 # used by _log_ssh_settings
        DEPLOY_SSH_PORT=2222
        DEPLOY_SSH_KEY="/path/to/key"
        DEPLOY_SSH_PASSWORD=""
        # shellcheck disable=SC2034 # used by _log_ssh_settings
        DEPLOY_SSH_PASSWORD_FILE=""

        _log_ssh_settings

        local has_user="false"
        echo "$captured_lines" | grep -q "admin" && has_user="true"
        _assert_eq "shows user" "true" "$has_user"

        local has_port="false"
        echo "$captured_lines" | grep -q "2222" && has_port="true"
        _assert_eq "shows port" "true" "$has_port"

        local has_key="false"
        echo "$captured_lines" | grep -q "Key:" && has_key="true"
        _assert_eq "shows key" "true" "$has_key"
    )
}

# ============================================================
# Test: SSH host key check default is accept-new
# ============================================================
_case_ssh_host_key_check_default() {
    echo "=== Test: SSH host key check default ==="
    (
        # Source variables.sh with a clean state
        unset DEPLOY_SSH_HOST_KEY_CHECK
        load_modules
        _assert_eq "DEPLOY_SSH_HOST_KEY_CHECK default is accept-new" "accept-new" "$DEPLOY_SSH_HOST_KEY_CHECK"
    )
    (
        # Ensure environment variable override still works
        DEPLOY_SSH_HOST_KEY_CHECK="yes"
        _assert_eq "DEPLOY_SSH_HOST_KEY_CHECK respects env override" "yes" "$DEPLOY_SSH_HOST_KEY_CHECK"
    )
}

# ============================================================
# Test: SSH key auto-discovery
# ============================================================
_case_auto_discover_ssh_key() {
    echo "=== Test: SSH key auto-discovery ==="
    load_modules

    # Setup: create temp dir with fake SSH keys
    local tmpdir
    tmpdir=$(mktemp -d)

    # Stub get_user_home so we don't need real user lookup
    get_user_home() { echo "$tmpdir"; }

    # Stub log_info to suppress output
    log_info() { :; }

    (
        # Test 1: Explicit key is not overridden
        DEPLOY_SSH_KEY="/explicit/path"
        _auto_discover_ssh_key
        _assert_eq "explicit key is preserved" "/explicit/path" "$DEPLOY_SSH_KEY"
    )

    (
        # Test 2: ed25519 is preferred
        mkdir -p "$tmpdir/.ssh"
        touch "$tmpdir/.ssh/id_ed25519"
        touch "$tmpdir/.ssh/id_rsa"
        touch "$tmpdir/.ssh/id_ecdsa"

        DEPLOY_SSH_KEY=""
        HOME="$tmpdir"
        _auto_discover_ssh_key
        _assert_eq "ed25519 preferred" "$tmpdir/.ssh/id_ed25519" "$DEPLOY_SSH_KEY"
    )

    (
        # Test 3: Falls back to rsa when ed25519 is absent
        rm -f "$tmpdir/.ssh/id_ed25519"

        DEPLOY_SSH_KEY=""
        HOME="$tmpdir"
        _auto_discover_ssh_key
        _assert_eq "rsa fallback" "$tmpdir/.ssh/id_rsa" "$DEPLOY_SSH_KEY"
    )

    (
        # Test 4: No key found, DEPLOY_SSH_KEY stays empty
        rm -rf "$tmpdir/.ssh"

        DEPLOY_SSH_KEY=""
        HOME="$tmpdir"
        _auto_discover_ssh_key
        _assert_eq "no key found leaves empty" "" "$DEPLOY_SSH_KEY"
    )

    rm -rf "$tmpdir"
}

@test "_parse_node_address" {
    _case_parse_node_address
}

@test "_build_deploy_ssh_opts" {
    _case_build_deploy_ssh_opts
}

@test "_setup_session_known_hosts / _teardown" {
    _case_session_known_hosts
}

@test "_bundle_dir_set / _bundle_dir_lookup" {
    _case_bundle_dir_store
}

@test "_validate_ssh_key_permissions (test_validate_ssh_key_permissions)" {
    _case_validate_ssh_key_permissions
}

@test "_load_ssh_password_file (test_load_ssh_password_file)" {
    _case_load_ssh_password_file
}

@test "--remote-timeout / --poll-interval parsing" {
    _case_timeout_cli_options
}

@test "_build_deploy_ssh_opts with key only" {
    _case_build_ssh_opts_key_only
}

@test "_build_deploy_ssh_opts with password" {
    _case_build_ssh_opts_password
}

@test "_build_deploy_ssh_opts with SSH agent" {
    _case_build_ssh_opts_ssh_agent
}

@test "_build_deploy_ssh_opts with SSH agent + explicit key" {
    _case_build_ssh_opts_agent_with_key
}

@test "_parse_node_address bare host" {
    _case_parse_node_address_bare_host
}

@test "_parse_node_address user@host" {
    _case_parse_node_address_user_at_host
}

@test "_parse_node_address IPv6 bracketed" {
    _case_parse_node_address_ipv6_bracketed
}

@test "_parse_node_address bare IPv6" {
    _case_parse_node_address_bare_ipv6
}

@test "_bundle_dir_set / _bundle_dir_lookup (deep)" {
    _case_bundle_dir_store_deep
}

@test "_setup_session_known_hosts / _teardown lifecycle" {
    _case_session_known_hosts_lifecycle
}

@test "_setup_session_known_hosts with seed file" {
    _case_session_known_hosts_seeded
}

@test "_validate_ssh_key_permissions (test_ssh_key_permission_validation)" {
    _case_ssh_key_permission_validation
}

@test "_load_ssh_password_file (test_ssh_password_file_loading)" {
    _case_ssh_password_file_loading
}

@test "_persist_known_hosts" {
    _case_persist_known_hosts
}

@test "_build_scp_args IPv6 bracketing" {
    _case_build_scp_args_ipv6
}

@test "_log_ssh_settings output" {
    _case_log_ssh_settings
}

@test "SSH host key check default" {
    _case_ssh_host_key_check_default
}

@test "SSH key auto-discovery" {
    _case_auto_discover_ssh_key
}
