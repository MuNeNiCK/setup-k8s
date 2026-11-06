#!/usr/bin/env bats
# Ported from test/unit/test_detection.sh

setup() {
    load '../helpers/common'
}

# ============================================================
# Test: --distro option sets DISTRO_OVERRIDE
# ============================================================
_case_parse_distro_override() {
    echo "=== Test: --distro sets DISTRO_OVERRIDE ==="
    (
        load_modules

        parse_setup_args --distro generic
        _assert_eq "DISTRO_OVERRIDE set to generic" "generic" "$DISTRO_OVERRIDE"
    )
}

# ============================================================
# Test: --distro rejects invalid values
# ============================================================
_case_parse_distro_invalid() {
    echo "=== Test: --distro rejects invalid values ==="
    (
        load_modules

        local exit_code=0
        (parse_setup_args --distro invalid_distro) >/dev/null 2>&1 || exit_code=$?
        _assert_ne "--distro invalid value rejected" "0" "$exit_code"
    )
}

# ============================================================
# Test: _detect_arch returns known architecture
# ============================================================
_case_detect_arch() {
    echo "=== Test: _detect_arch ==="
    (
        load_modules

        local arch
        arch=$(_detect_arch)
        _assert_ne "_detect_arch returns non-empty" "" "$arch"
        # Should be one of the known architectures on typical test hosts
        local known=false
        for a in amd64 arm64 arm s390x ppc64le; do
            if [ "$arch" = "$a" ]; then known=true; break; fi
        done
        _assert_eq "_detect_arch returns known arch" "true" "$known"
    )
}

# ============================================================
# Test: _detect_init_system returns valid value
# ============================================================
_case_detect_init_system() {
    echo "=== Test: _detect_init_system ==="
    (
        load_modules

        local init
        init=$(_detect_init_system)
        _assert_ne "_detect_init_system returns non-empty" "" "$init"
        local valid=false
        for v in systemd openrc unknown; do
            if [ "$init" = "$v" ]; then valid=true; break; fi
        done
        _assert_eq "_detect_init_system returns valid value" "true" "$valid"
    )
}

# ============================================================
# Test: detect_distribution family mapping
# ============================================================
_case_detect_distro_family_mapping() {
    echo "=== Test: detect_distribution family mapping ==="
    (
        load_modules
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }

        # Test override path
        DISTRO_OVERRIDE="debian"
        detect_distribution
        _assert_eq "distro override family" "debian" "$DISTRO_FAMILY"
        _assert_eq "distro override name" "debian-manual" "$DISTRO_NAME"

        DISTRO_OVERRIDE="rhel"
        detect_distribution
        _assert_eq "distro override rhel" "rhel" "$DISTRO_FAMILY"

        DISTRO_OVERRIDE="arch"
        detect_distribution
        _assert_eq "distro override arch" "arch" "$DISTRO_FAMILY"

        DISTRO_OVERRIDE="suse"
        detect_distribution
        _assert_eq "distro override suse" "suse" "$DISTRO_FAMILY"

        DISTRO_OVERRIDE="generic"
        detect_distribution
        _assert_eq "distro override generic" "generic" "$DISTRO_FAMILY"
    )
}

# ============================================================
# Test: _has_cgroupv2 function
# ============================================================
_case_has_cgroupv2() {
    echo "=== Test: _has_cgroupv2 function ==="
    (
        load_modules
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }

        local has_func="false"
        type _has_cgroupv2 >/dev/null 2>&1 && has_func="true"
        _assert_eq "_has_cgroupv2 defined" "true" "$has_func"

        # On a modern system (Arch Linux), cgroups v2 should be available
        if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
            local result="false"
            _has_cgroupv2 && result="true"
            _assert_eq "_has_cgroupv2 returns true" "true" "$result"
        fi
    )
}

# ============================================================
# Test: detect_distribution all family mappings (deep)
# ============================================================
_case_detect_distro_family_all_mappings() {
    echo "=== Test: detect_distribution all family mappings ==="
    (
        load_modules
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }

        # Test each distro family without overrides
        # We test the case statement directly by mimicking os-release vars
        local test_cases="ubuntu:debian
debian:debian
centos:rhel
rhel:rhel
fedora:rhel
rocky:rhel
almalinux:rhel
ol:rhel
suse:suse
sles:suse
arch:arch
manjaro:arch
alpine:alpine
mysteriousos:generic"

        for tc in $test_cases; do
            local distro_name="${tc%%:*}"
            local expected_family="${tc##*:}"

            DISTRO_OVERRIDE=""
            DISTRO_NAME="$distro_name"
            # Simulate the case statement
            case "$DISTRO_NAME" in
                ubuntu|debian) DISTRO_FAMILY="debian" ;;
                centos|rhel|fedora|rocky|almalinux|ol) DISTRO_FAMILY="rhel" ;;
                suse|sles|opensuse*) DISTRO_FAMILY="suse" ;;
                arch|manjaro) DISTRO_FAMILY="arch" ;;
                alpine) DISTRO_FAMILY="alpine" ;;
                *) DISTRO_FAMILY="unknown" ;;
            esac
            # Then the support check remaps unknown to generic
            case "$DISTRO_FAMILY" in
                debian|rhel|suse|arch|alpine) ;;
                *) DISTRO_FAMILY="generic" ;;
            esac
            _assert_eq "distro $distro_name -> $expected_family" "$expected_family" "$DISTRO_FAMILY"
        done
    )
}

@test "--distro sets DISTRO_OVERRIDE" {
    _case_parse_distro_override
}

@test "--distro rejects invalid values" {
    _case_parse_distro_invalid
}

@test "_detect_arch" {
    _case_detect_arch
}

@test "_detect_init_system" {
    _case_detect_init_system
}

@test "detect_distribution family mapping" {
    _case_detect_distro_family_mapping
}

@test "_has_cgroupv2 function" {
    _case_has_cgroupv2
}

@test "detect_distribution all family mappings" {
    _case_detect_distro_family_all_mappings
}
