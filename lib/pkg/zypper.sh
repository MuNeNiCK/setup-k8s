#!/bin/sh

# zypper adapter (openSUSE, SLES). See lib/pkg/pkg.sh for the interface.

_pkg_zypper_refresh() {
    zypper --non-interactive --gpg-auto-import-keys refresh
}

_pkg_zypper_base_deps() {
    echo "curl iptables iproute2 ethtool conntrack-tools socat kmod"
}

# Newest patch of <minor> available for <name> (installed or not)
_pkg_zypper_minor_version() {
    zypper --non-interactive search -s --match-exact "$1" 2>/dev/null \
        | awk -F'|' -v n="$1" '{ gsub(/ /, "", $2); gsub(/ /, "", $4); if ($2 == n) print $4 }' \
        | sed 's/-.*//' | _pkg_newest_patch "$2"
}

_pkg_zypper_install() {
    _pkg_parse_install_args "$@"
    _pkg_resolve_minor_specs _pkg_zypper_minor_version
    local spec name names
    names=$(_pkg_spec_names)
    set --
    for spec in $_PKG_SPECS; do
        name="${spec%%=*}"
        if [ "$spec" = "$name" ]; then
            set -- "$@" "$name"
        else
            case "${spec#*=}" in
                *.*.*) set -- "$@" "${name}=$(_pkg_version_native "${spec#*=}")" ;;
                *)     set -- "$@" "$name" ;;  # repositories are per minor version
            esac
        fi
    done
    [ "$_PKG_NO_WEAK" = true ] && set -- --no-recommends "$@"
    if [ "$_PKG_HOLD" = true ]; then
        # shellcheck disable=SC2086 # names are space-separated package names
        zypper --non-interactive removelock $names >/dev/null 2>&1 || true
    fi
    zypper --non-interactive install -y --allow-vendor-change --replacefiles --oldpackage "$@" || return 1
    if [ "$_PKG_HOLD" = true ]; then
        # shellcheck disable=SC2086
        zypper --non-interactive addlock $names >/dev/null || log_warn "zypper addlock failed; packages are not pinned"
    fi
}

_pkg_zypper_remove() {
    local installed
    installed=$(_pkg_filter_installed "$@")
    [ -z "$installed" ] && return 0
    # shellcheck disable=SC2086
    zypper --non-interactive removelock $installed >/dev/null 2>&1 || true
    # shellcheck disable=SC2086
    zypper --non-interactive remove -y $installed
}

_pkg_zypper_installed() {
    rpm -q "$1" >/dev/null 2>&1
}

_pkg_zypper_available_version() {
    zypper --non-interactive info "$1" 2>/dev/null | awk -F': *' '/^Version/ {print $2; exit}' | sed 's/-.*//'
}

_pkg_zypper_repo_add() {
    local id="$1" url="$2" key_url="$3"
    rpm --import "$key_url" || { log_error "Failed to import repository key: $key_url"; return 1; }
    zypper --non-interactive removerepo "$id" >/dev/null 2>&1 || true
    zypper --non-interactive addrepo --gpgcheck --refresh "$url" "$id" || return 1
    zypper --non-interactive --gpg-auto-import-keys refresh "$id"
}

_pkg_zypper_repo_remove() {
    zypper --non-interactive removerepo "$1" >/dev/null 2>&1 || true
}
