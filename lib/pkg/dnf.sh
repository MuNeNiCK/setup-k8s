#!/bin/sh

# dnf adapter (RHEL, CentOS Stream, Rocky, AlmaLinux, Oracle Linux, Fedora).
# Falls back to yum where dnf is not installed. See lib/pkg/pkg.sh for the
# interface.
#
# Repositories are written directly to /etc/yum.repos.d/<id>.repo, which
# works the same on dnf4, dnf5, and yum. Held packages are listed in the
# repository's exclude= line, as in the upstream Kubernetes instructions, and
# installs from that repository lift the exclude for the transaction.

# Repository directory (overridable for tests)
_DNF_REPOS_DIR="/etc/yum.repos.d"

_pkg_dnf_bin() {
    if command -v dnf >/dev/null 2>&1; then echo dnf; else echo yum; fi
}

# Succeed when the package manager is dnf5.
_pkg_dnf_is_v5() {
    [ "$(_pkg_dnf_bin)" = dnf ] || return 1
    dnf --version 2>/dev/null | head -n 1 | grep -qE '^(dnf5|5\.)'
}

_pkg_dnf_refresh() {
    "$(_pkg_dnf_bin)" makecache -y
}

_pkg_dnf_base_deps() {
    echo "curl gnupg2 iptables iptables-services ethtool iproute conntrack-tools socat ebtables kmod"
}

# Add package names to the exclude= line of a repository file.
_pkg_dnf_exclude_add() {
    local file="${_DNF_REPOS_DIR}/$1.repo"
    shift
    [ -f "$file" ] || return 0
    local current name merged
    current=$(sed -n 's/^exclude=//p' "$file")
    merged="$current"
    for name in "$@"; do
        case " $merged " in
            *" $name "*) ;;
            *) merged="${merged}${merged:+ }${name}" ;;
        esac
    done
    if grep -q '^exclude=' "$file"; then
        sed -i "s/^exclude=.*/exclude=${merged}/" "$file"
    else
        echo "exclude=${merged}" >> "$file"
    fi
}

_pkg_dnf_install() {
    _pkg_parse_install_args "$@"
    local spec name bin
    bin=$(_pkg_dnf_bin)
    set --
    for spec in $_PKG_SPECS; do
        name="${spec%%=*}"
        if [ "$spec" = "$name" ]; then
            set -- "$@" "$name"
        else
            case "${spec#*=}" in
                *.*.*) set -- "$@" "${name}-${spec#*=}-*" ;;
                *)     set -- "$@" "$name" ;;  # repositories are per minor version
            esac
        fi
    done
    [ "$_PKG_NO_WEAK" = true ] && set -- --setopt=install_weak_deps=False "$@"
    if [ -n "$_PKG_REPO" ] && [ -f "${_DNF_REPOS_DIR}/${_PKG_REPO}.repo" ]; then
        if _pkg_dnf_is_v5; then
            set -- "--setopt=disable_excludes=${_PKG_REPO}" "$@"
        else
            set -- "--disableexcludes=${_PKG_REPO}" "$@"
        fi
    fi
    "$bin" install -y "$@" || return 1
    # "install" leaves a newer installed version in place; downgrade packages
    # pinned to an exact older version (rollback).
    local older="" installed_ver opts=""
    for spec in $_PKG_SPECS; do
        name="${spec%%=*}"
        [ "$spec" = "$name" ] && continue
        case "${spec#*=}" in
            *.*.*)
                installed_ver=$(rpm -q --qf '%{VERSION}' "$name" 2>/dev/null) || installed_ver=""
                if [ -n "$installed_ver" ] && [ "$installed_ver" != "${spec#*=}" ]; then
                    older="${older}${older:+ }${name}-${spec#*=}"
                fi
                ;;
        esac
    done
    if [ -n "$older" ]; then
        if [ -n "$_PKG_REPO" ] && [ -f "${_DNF_REPOS_DIR}/${_PKG_REPO}.repo" ]; then
            if _pkg_dnf_is_v5; then opts="--setopt=disable_excludes=${_PKG_REPO}"; else opts="--disableexcludes=${_PKG_REPO}"; fi
        fi
        # shellcheck disable=SC2086 # space-separated options and package specs
        "$bin" downgrade -y $opts $older || return 1
    fi
    if [ "$_PKG_HOLD" = true ] && [ -n "$_PKG_REPO" ]; then
        # shellcheck disable=SC2046 # names are space-separated package names
        _pkg_dnf_exclude_add "$_PKG_REPO" $(_pkg_spec_names)
    fi
}

_pkg_dnf_remove() {
    local installed bin
    installed=$(_pkg_filter_installed "$@")
    [ -z "$installed" ] && return 0
    bin=$(_pkg_dnf_bin)
    # shellcheck disable=SC2086
    "$bin" remove -y $installed || return 1
    "$bin" autoremove -y >/dev/null 2>&1 || true
}

_pkg_dnf_installed() {
    rpm -q "$1" >/dev/null 2>&1
}

_pkg_dnf_available_version() {
    "$(_pkg_dnf_bin)" -q list --available "$1" 2>/dev/null | awk -v n="$1" '$1 ~ "^"n"\\." {print $2}' | tail -n 1 | sed 's/^[0-9]*://; s/-.*//'
}

_pkg_dnf_repo_add() {
    local id="$1" url="$2" key_url="$3"
    mkdir -p "$_DNF_REPOS_DIR"
    cat > "${_DNF_REPOS_DIR}/${id}.repo" <<EOF
[${id}]
name=${id}
baseurl=${url}
enabled=1
gpgcheck=1
gpgkey=${key_url}
EOF
    "$(_pkg_dnf_bin)" makecache -y --repo "$id" >/dev/null 2>&1 || "$(_pkg_dnf_bin)" makecache -y
}

_pkg_dnf_repo_remove() {
    rm -f "${_DNF_REPOS_DIR}/$1.repo"
}
