#!/bin/sh

# apk adapter (Alpine). See lib/pkg/pkg.sh for the interface.
#
# A version constraint (NAME=~VERSION) is recorded in /etc/apk/world, so
# versioned installs stay pinned until the constraint changes.

# Enable the community repository, which carries Kubernetes and runtimes.
_pkg_apk_enable_community() {
    local repo_file="/etc/apk/repositories" mirror
    if grep -qE '^\s*#.*/community\s*$' "$repo_file" 2>/dev/null; then
        log_info "Enabling Alpine community repository..."
        sed -i 's|^#\(.*/community\)[[:space:]]*$|\1|' "$repo_file"
    elif ! grep -q '/community' "$repo_file" 2>/dev/null; then
        mirror=$(grep -m1 '^http.*/main' "$repo_file" | sed 's|/main.*|/community|')
        if [ -n "$mirror" ]; then
            log_info "Adding Alpine community repository..."
            echo "$mirror" >> "$repo_file"
        else
            log_warn "Could not determine the community repository URL; packages may be unavailable"
        fi
    fi
}

_pkg_apk_refresh() {
    _pkg_apk_enable_community
    apk update
}

_pkg_apk_base_deps() {
    echo "bash curl ca-certificates conntrack-tools socat ethtool iproute2 iptables kmod cgroup-tools"
}

_pkg_apk_install() {
    _pkg_parse_install_args "$@"
    local spec name
    set --
    for spec in $_PKG_SPECS; do
        name="${spec%%=*}"
        if [ "$spec" = "$name" ]; then
            set -- "$@" "$name"
        else
            set -- "$@" "${name}=~${spec#*=}"
        fi
    done
    apk add --no-cache "$@"
}

_pkg_apk_remove() {
    local installed
    installed=$(_pkg_filter_installed "$@")
    [ -z "$installed" ] && return 0
    # shellcheck disable=SC2086
    apk del $installed
}

_pkg_apk_installed() {
    apk info -e "$1" >/dev/null 2>&1
}

_pkg_apk_available_version() {
    apk policy "$1" 2>/dev/null | awk 'NR == 2 {sub(/:$/, "", $1); print $1}' | sed 's/-r[0-9]*$//'
}

_pkg_apk_repo_add() {
    log_error "Adding repositories is not supported for apk"
    return 1
}

_pkg_apk_repo_remove() {
    return 0
}
