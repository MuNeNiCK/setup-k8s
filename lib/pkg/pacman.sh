#!/bin/sh

# pacman adapter (Arch Linux, Manjaro). See lib/pkg/pkg.sh for the interface.
#
# Arch does not support partial upgrades, so refreshing performs a full
# system upgrade (kernels excluded to avoid a reboot). Repositories carry only
# the current version of each package; versions in specs are not enforced.

_PKG_PACMAN_KERNELS="linux,linux-headers,linux-lts,linux-lts-headers,linux-zen,linux-zen-headers,linux-hardened,linux-hardened-headers"

_pkg_pacman_refresh() {
    pacman -Syu --noconfirm --ignore "$_PKG_PACMAN_KERNELS"
}

_pkg_pacman_base_deps() {
    echo "curl sudo conntrack-tools socat ethtool iproute2 iptables kmod"
}

_pkg_pacman_install() {
    _pkg_parse_install_args "$@"
    local spec name version
    set --
    for spec in $_PKG_SPECS; do
        name="${spec%%=*}"
        if [ "$spec" != "$name" ]; then
            version=$(_pkg_pacman_available_version "$name")
            case "$version" in
                "${spec#*=}"|"${spec#*=}".*) ;;
                *) log_warn "pacman installs ${name} ${version:-unknown}; version ${spec#*=} cannot be pinned" ;;
            esac
        fi
        # Skip targets already satisfied by an installed package or provider
        # (e.g. iptables provided by iptables-nft).
        if [ -n "$(pacman -T "$name" 2>/dev/null)" ]; then
            set -- "$@" "$name"
        fi
    done
    [ $# -eq 0 ] && return 0
    # --ask 4 accepts replacing conflicting packages (e.g. iptables by iptables-nft)
    pacman -S --noconfirm --needed --ask 4 "$@"
}

_pkg_pacman_remove() {
    local installed
    installed=$(_pkg_filter_installed "$@")
    [ -z "$installed" ] && return 0
    # shellcheck disable=SC2086
    pacman -Rdd --noconfirm $installed
}

# Exact package name (pacman -Qi also matches packages that only provide it)
_pkg_pacman_installed() {
    pacman -Qq 2>/dev/null | grep -qxF "$1"
}

_pkg_pacman_available_version() {
    pacman -Si "$1" 2>/dev/null | awk -F': *' '/^Version/ {print $2; exit}' | sed 's/^[0-9]*://; s/-[0-9.]*$//'
}

_pkg_pacman_repo_add() {
    log_error "Adding repositories is not supported for pacman"
    return 1
}

_pkg_pacman_repo_remove() {
    return 0
}
