#!/usr/bin/env bats
# Ported from test/unit/test_swap.sh

setup() {
    load '../helpers/common'
}

# ============================================================
# Test: --swap-enabled flag parsing and default
# ============================================================
_case_swap_enabled_default() {
    echo "=== Test: SWAP_ENABLED default ==="
    (
        load_modules
        _assert_eq "SWAP_ENABLED default" "false" "$SWAP_ENABLED"
    )
}

_case_parse_swap_enabled() {
    echo "=== Test: parse_setup_args --swap-enabled ==="
    (
        load_modules

        parse_setup_args --swap-enabled
        _assert_eq "SWAP_ENABLED parsed" "true" "$SWAP_ENABLED"
    )
}

# ============================================================
# Test: validate_swap_enabled version check
# ============================================================
_case_validate_swap_enabled() {
    echo "=== Test: validate_swap_enabled ==="
    (
        load_modules

        # swap enabled with K8s 1.32 should pass
        SWAP_ENABLED=true
        K8S_VERSION="1.32"
        validate_swap_enabled
        _assert_eq "swap enabled 1.32 passes" "true" "$SWAP_ENABLED"

        # swap enabled with K8s 1.30 (NodeSwap on by default) should pass
        SWAP_ENABLED=true
        K8S_VERSION="1.30"
        validate_swap_enabled
        _assert_eq "swap enabled 1.30 passes" "true" "$SWAP_ENABLED"

        # swap enabled with K8s 1.29 (NodeSwap off by default) should fail
        SWAP_ENABLED=true
        K8S_VERSION="1.29"
        local exit_code=0
        (validate_swap_enabled) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "swap enabled 1.29 rejected" "0" "$exit_code"

        # swap disabled should always pass regardless of version
        SWAP_ENABLED=false
        # shellcheck disable=SC2034 # used by validate_swap_enabled
        K8S_VERSION="1.25"
        validate_swap_enabled
        _assert_eq "swap disabled always passes" "false" "$SWAP_ENABLED"
    )
}

# ============================================================
# Test: swap.sh core functions defined
# ============================================================
_case_swap_functions_defined() {
    echo "=== Test: swap.sh core functions defined ==="
    (
        load_modules
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }

        local has_disable="false"
        type disable_swap >/dev/null 2>&1 && has_disable="true"
        _assert_eq "disable_swap defined" "true" "$has_disable"

        local has_restore_fstab="false"
        type restore_fstab_swap >/dev/null 2>&1 && has_restore_fstab="true"
        _assert_eq "restore_fstab_swap defined" "true" "$has_restore_fstab"

        local has_disable_zram="false"
        type disable_zram_swap >/dev/null 2>&1 && has_disable_zram="true"
        _assert_eq "disable_zram_swap defined" "true" "$has_disable_zram"

        local has_restore_zram="false"
        type restore_zram_swap >/dev/null 2>&1 && has_restore_zram="true"
        _assert_eq "restore_zram_swap defined" "true" "$has_restore_zram"
    )
}

# ============================================================
# Test: swap disable fstab sed pattern
# ============================================================
_case_swap_fstab_sed_pattern() {
    echo "=== Test: swap disable fstab sed pattern ==="
    (
        load_modules
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }

        # Create a fake fstab
        local tmpfstab
        tmpfstab=$(mktemp /tmp/test-fstab-XXXXXX)

        cat > "$tmpfstab" <<'FSTAB'
UUID=abc-123 / ext4 defaults 0 1
UUID=def-456 none swap sw 0 0
/dev/sda2 none swap sw 0 0
# already commented swap line
#UUID=ghi-789 none swap sw 0 0
/dev/mapper/data /data xfs defaults 0 2
FSTAB

        # Apply the same sed pattern used in disable_swap
        sed -i '/^[^#].*[[:space:]]swap[[:space:]]/ s/^/#/' "$tmpfstab"

        # Verify swap lines are commented
        local uncommented_swap
        uncommented_swap=$(grep '^[^#].*[[:space:]]swap[[:space:]]' "$tmpfstab" || true)
        _assert_eq "no uncommented swap lines" "" "$uncommented_swap"

        # Verify non-swap lines are untouched
        local has_root="false"
        grep -q "UUID=abc-123 / ext4" "$tmpfstab" && has_root="true"
        _assert_eq "root mount untouched" "true" "$has_root"

        local has_data="false"
        grep -q "/dev/mapper/data /data xfs" "$tmpfstab" && has_data="true"
        _assert_eq "data mount untouched" "true" "$has_data"

        # Verify the originally-commented swap line wasn't double-commented
        local double_commented
        double_commented=$(grep '^##' "$tmpfstab" || true)
        _assert_eq "no double-commented lines" "" "$double_commented"

        rm -f "$tmpfstab"
    )
}

@test "SWAP_ENABLED default" {
    _case_swap_enabled_default
}

@test "parse_setup_args --swap-enabled" {
    _case_parse_swap_enabled
}

@test "validate_swap_enabled" {
    _case_validate_swap_enabled
}

@test "swap.sh core functions defined" {
    _case_swap_functions_defined
}

@test "swap disable fstab sed pattern" {
    _case_swap_fstab_sed_pattern
}

# --- swap stays off across reboots ---

# Fake systemctl: one swap unit outside fstab, one zram unit.
_fake_systemd_with_swap_unit() {
    cat > "$FAKE_BIN/systemctl" <<FAKE
#!/bin/sh
echo "systemctl \$*" >> "$FAKE_LOG"
case "\$*" in
    --version) echo "systemd 255" ;;
    "list-units --type=swap --all --plain --no-legend")
        printf '%s\n' 'swapfile\\x2dunit.swap loaded active active /swapfile-unit' 'dev-zram0.swap loaded active active /dev/zram0' ;;
    "list-unit-files --type=swap --plain --no-legend")
        printf '%s\n' 'swapfile\\x2dunit.swap enabled enabled' ;;
    "is-enabled "*) echo enabled ;;
esac
exit 0
FAKE
    chmod +x "$FAKE_BIN/systemctl"
    fake_cmd swapoff
    fake_cmd swapon
}

@test "disable_swap comments fstab entries and blocks systemd swap units" {
    load_modules; quiet_logs
    _fake_systemd_with_swap_unit
    _FSTAB_FILE="$BATS_TEST_TMPDIR/fstab"
    _SWAP_UNITS_MARKER="$BATS_TEST_TMPDIR/swap-units"
    _SYSTEMD_UNIT_DIR="$BATS_TEST_TMPDIR/systemd"
    printf '%s\n' 'UUID=abc / ext4 defaults 0 1' '/swapfile none swap sw 0 0' > "$_FSTAB_FILE"

    disable_swap

    grep -qx '#/swapfile none swap sw 0 0' "$_FSTAB_FILE"
    grep -qx 'UUID=abc / ext4 defaults 0 1' "$_FSTAB_FILE"
    # A drop-in prevents the unit from starting at boot (zram is handled separately)
    grep -q '^ConditionPathExists=/nonexistent/' "$_SYSTEMD_UNIT_DIR/swapfile\x2dunit.swap.d/$_SWAP_DROPIN_NAME"
    [ ! -e "$_SYSTEMD_UNIT_DIR/dev-zram0.swap.d" ]
    fake_calls | grep -qxF 'systemctl stop swapfile\x2dunit.swap'
    [ "$(cat "$_SWAP_UNITS_MARKER")" = 'swapfile\x2dunit.swap' ]
    fake_calls | grep -qx 'swapoff -a'
}

@test "restore_fstab_swap restores fstab entries and unblocks recorded units" {
    load_modules; quiet_logs
    _fake_systemd_with_swap_unit
    _FSTAB_FILE="$BATS_TEST_TMPDIR/fstab"
    _SWAP_UNITS_MARKER="$BATS_TEST_TMPDIR/swap-units"
    _SYSTEMD_UNIT_DIR="$BATS_TEST_TMPDIR/systemd"
    printf '%s\n' 'UUID=abc / ext4 defaults 0 1' '/swapfile none swap sw 0 0' > "$_FSTAB_FILE"
    disable_swap
    : > "$FAKE_LOG"

    restore_fstab_swap

    grep -qx '/swapfile none swap sw 0 0' "$_FSTAB_FILE"
    if grep -q '^#/swapfile' "$_FSTAB_FILE"; then return 1; fi
    [ ! -e "$_SYSTEMD_UNIT_DIR/swapfile\x2dunit.swap.d" ]
    fake_calls | grep -qx 'systemctl start swap.target'
    fake_calls | grep -qx 'swapon -a'
    [ ! -e "$_SWAP_UNITS_MARKER" ]
}

@test "restore_fstab_swap leaves swap alone when setup-k8s changed nothing" {
    load_modules; quiet_logs
    _fake_systemd_with_swap_unit
    _FSTAB_FILE="$BATS_TEST_TMPDIR/fstab"
    _SWAP_UNITS_MARKER="$BATS_TEST_TMPDIR/swap-units"
    _SYSTEMD_UNIT_DIR="$BATS_TEST_TMPDIR/systemd"
    printf '%s\n' 'UUID=abc / ext4 defaults 0 1' > "$_FSTAB_FILE"

    restore_fstab_swap

    if fake_calls | grep -q -e 'start swap.target' -e 'swapon -a'; then return 1; fi
}
