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

# Detect with a fixture os-release and print the resulting values.
# Usage: _detect_with <os-release lines...>
_detect_with() {
    printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/os-release"
    _OS_RELEASE_FILE="$BATS_TEST_TMPDIR/os-release"
    DISTRO_OVERRIDE="${DISTRO_OVERRIDE:-}"
    detect_distribution
    printf '%s|%s|%s|%s|%s|%s|%s\n' "$DISTRO_FAMILY" "$DISTRO_PKG" "$DISTRO_K8S_SOURCE" \
        "$DISTRO_CONTAINERD_SOURCE" "$DISTRO_CRIO_SOURCE" "$DISTRO_DOCKER_REPO" "$DISTRO_CODENAME"
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


@test "_has_cgroupv2 function" {
    _case_has_cgroupv2
}

@test "detect_distribution: Debian and Ubuntu use pkgs.k8s.io, Docker containerd, isv:cri-o" {
    load_modules; quiet_logs
    run _detect_with ID=ubuntu VERSION_ID=24.04 VERSION_CODENAME=noble UBUNTU_CODENAME=noble
    [ "$output" = "debian|apt|pkgs|docker|isv|ubuntu|noble" ]
    run _detect_with ID=debian VERSION_ID=13 VERSION_CODENAME=trixie
    [ "$output" = "debian|apt|pkgs|docker|isv|debian|trixie" ]
}

@test "detect_distribution: Ubuntu derivatives use ID_LIKE and the Ubuntu codename" {
    load_modules; quiet_logs
    run _detect_with ID=linuxmint 'ID_LIKE="ubuntu debian"' VERSION_ID=22 VERSION_CODENAME=wilma UBUNTU_CODENAME=noble
    [ "$output" = "debian|apt|pkgs|docker|isv|ubuntu|noble" ]
}

@test "detect_distribution: RHEL family selects the Docker repository by ID" {
    load_modules; quiet_logs
    local id
    for id in rhel rocky almalinux ol; do
        run _detect_with "ID=$id" VERSION_ID=9.6
        [ "$output" = "rhel|dnf|pkgs|docker|isv|rhel|" ]
    done
    run _detect_with ID=fedora VERSION_ID=44
    [ "$output" = "rhel|dnf|pkgs|docker|isv|fedora|" ]
    run _detect_with ID=centos VERSION_ID=10
    [ "$output" = "rhel|dnf|pkgs|docker|isv|centos|" ]
}

@test "detect_distribution: openSUSE Tumbleweed and Leap differ only in the containerd source" {
    load_modules; quiet_logs
    run _detect_with ID=opensuse-tumbleweed VERSION_ID=20261101
    [ "$output" = "suse|zypper|pkgs|distro|isv||" ]
    _detect_with ID=opensuse-leap VERSION_ID=16.0 >/dev/null
    [ "$DISTRO_CONTAINERD_SOURCE" = obs ]
    [ "$DISTRO_OBS_REPO" = "Virtualization:/containers/16.0" ]
}

@test "detect_distribution: Alpine and Arch use distribution packages" {
    load_modules; quiet_logs
    run _detect_with ID=alpine VERSION_ID=3.24.0
    [ "$output" = "alpine|apk|distro|distro|distro||" ]
    run _detect_with ID=arch
    [ "$output" = "arch|pacman|distro|distro|distro||" ]
    run _detect_with ID=manjaro 'ID_LIKE=arch'
    [ "$output" = "arch|pacman|distro|distro|distro||" ]
}

@test "detect_distribution: unknown distributions use release binaries" {
    load_modules; quiet_logs
    _detect_with ID=mysteriousos >/dev/null
    [ "$DISTRO_FAMILY" = generic ]
    [ "$DISTRO_K8S_SOURCE" = binary ]
    [ "$DISTRO_CONTAINERD_SOURCE" = binary ]
    [ "$DISTRO_CRIO_SOURCE" = binary ]
}

@test "detect_distribution: --distro overrides the family but keeps the real ID" {
    load_modules; quiet_logs
    DISTRO_OVERRIDE=generic _detect_with ID=ubuntu VERSION_CODENAME=noble >/dev/null
    [ "$DISTRO_FAMILY" = generic ]
    [ "$DISTRO_NAME" = ubuntu ]
    [ "$DISTRO_K8S_SOURCE" = binary ]
}
