#!/bin/sh

# apt adapter (Debian, Ubuntu). See lib/pkg/pkg.sh for the interface.

# Repository locations (overridable for tests)
_APT_SOURCES_DIR="/etc/apt/sources.list.d"
_APT_KEYRING_DIR="/etc/apt/keyrings"

_pkg_apt_refresh() {
    apt-get update
}

_pkg_apt_base_deps() {
    echo "apt-transport-https ca-certificates curl gnupg conntrack socat ethtool iproute2 iptables kmod"
}

# Print the apt version string of <name> matching <version>.
# MAJOR.MINOR.PATCH matches "PATCH-*" exactly; MAJOR.MINOR matches the newest
# "MINOR.*". Fails when nothing matches.
_pkg_apt_resolve_version() {
    local name="$1" version="$2" prefix candidates match
    case "$version" in
        *.*.*) prefix="${version}-" ;;
        *)     prefix="${version}." ;;
    esac
    candidates=$(apt-cache madison "$name" 2>/dev/null | awk -F'|' '{gsub(/ /, "", $2); print $2}')
    match=$(printf '%s\n' "$candidates" | awk -v p="$prefix" 'index($0, p) == 1 {print; exit}')
    if [ -z "$match" ]; then
        log_error "Version ${version} of ${name} is not available from apt repositories"
        return 1
    fi
    echo "$match"
}

_pkg_apt_install() {
    _pkg_parse_install_args "$@"
    local names spec name native
    names=$(_pkg_spec_names)
    set --
    for spec in $_PKG_SPECS; do
        name="${spec%%=*}"
        if [ "$spec" != "$name" ]; then
            native=$(_pkg_apt_resolve_version "$name" "${spec#*=}") || return 1
            set -- "$@" "${name}=${native}"
        else
            set -- "$@" "$name"
        fi
    done
    [ "$_PKG_NO_WEAK" = true ] && set -- --no-install-recommends "$@"
    if [ "$_PKG_HOLD" = true ]; then
        # shellcheck disable=SC2086 # names are space-separated package names
        apt-mark unhold $names >/dev/null 2>&1 || true
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-change-held-packages --allow-downgrades "$@" || return 1
    if [ "$_PKG_HOLD" = true ]; then
        # shellcheck disable=SC2086
        apt-mark hold $names >/dev/null
    fi
}

_pkg_apt_remove() {
    local installed
    installed=$(_pkg_filter_installed "$@")
    [ -z "$installed" ] && return 0
    # shellcheck disable=SC2086
    apt-mark unhold $installed >/dev/null 2>&1 || true
    # shellcheck disable=SC2086
    DEBIAN_FRONTEND=noninteractive apt-get purge -y $installed || return 1
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y >/dev/null 2>&1 || true
}

# Status is "<want> <flag> <status>"; held packages report "hold ok installed".
_pkg_apt_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q ' installed$'
}

_pkg_apt_available_version() {
    apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2; exit}' | sed 's/^[0-9]*://; s/-.*//'
}

_pkg_apt_repo_add() {
    local id="$1" url="$2" key_url="$3" suite="${4:-/}" components="${5:-}"
    local keyring="${_APT_KEYRING_DIR}/${id}.gpg" key_tmp
    mkdir -p "$_APT_KEYRING_DIR" "$_APT_SOURCES_DIR"
    key_tmp=$(mktemp)
    if ! _pkg_fetch_key "$key_url" "$key_tmp"; then
        rm -f "$key_tmp"
        return 1
    fi
    if ! gpg --batch --yes --dearmor -o "$keyring" "$key_tmp"; then
        rm -f "$key_tmp"
        log_error "Failed to import repository key: $key_url"
        return 1
    fi
    rm -f "$key_tmp"
    chmod 0644 "$keyring"
    if [ "$suite" = "/" ]; then
        echo "deb [signed-by=${keyring}] ${url} /" > "${_APT_SOURCES_DIR}/${id}.list"
    else
        echo "deb [arch=$(dpkg --print-architecture) signed-by=${keyring}] ${url} ${suite} ${components}" > "${_APT_SOURCES_DIR}/${id}.list"
    fi
    apt-get update
}

_pkg_apt_repo_remove() {
    local id
    for id in "$@"; do
        rm -f "${_APT_SOURCES_DIR}/${id}.list" "${_APT_KEYRING_DIR}/${id}.gpg"
    done
}
