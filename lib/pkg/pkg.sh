#!/bin/sh

# Package management interface.
#
# The adapter is chosen by DISTRO_PKG (set by detect_distribution):
# apt, dnf, zypper, apk, or pacman. Adapters live in lib/pkg/<manager>.sh and
# implement _pkg_<manager>_<operation>. Callers use only the functions below
# and never test distribution names.
#
#   pkg_refresh                         Refresh package metadata
#   pkg_install [opts] SPEC...          Install or change packages
#       --hold          protect the packages from routine system upgrades
#       --repo ID       the packages come from repository ID (added with pkg_repo_add)
#       --no-weak-deps  do not install recommended / weak dependencies
#     SPEC is NAME or NAME=VERSION, where VERSION is MAJOR.MINOR or
#     MAJOR.MINOR.PATCH. The adapter maps it to its own version syntax and
#     fails if the version is not available.
#   pkg_remove NAME...                  Remove installed packages (missing ones are ignored)
#   pkg_installed NAME                  Succeed if NAME is installed
#   pkg_available_version NAME          Print the candidate version of NAME
#   pkg_repo_add ID URL KEY_URL [SUITE [COMPONENTS]]
#                                       Add a signed repository. For deb, SUITE
#                                       defaults to "/" (flat repository). For rpm,
#                                       URL is the baseurl.
#   pkg_repo_remove ID                  Remove a repository added with pkg_repo_add
#   pkg_base_dependencies               Print the native names of tools every node needs
#   pkg_format                          Print deb, rpm, apk, or pacman

_pkg_call() {
    local op="$1"
    shift
    if [ -z "${DISTRO_PKG:-}" ]; then
        log_error "No supported package manager found on this system"
        return 1
    fi
    "_pkg_${DISTRO_PKG}_${op}" "$@"
}

pkg_install()            { _pkg_call install "$@"; }
pkg_remove()             { _pkg_call remove "$@"; }
pkg_installed()          { _pkg_call installed "$@"; }
pkg_available_version()  { _pkg_call available_version "$@"; }
pkg_repo_add()           { _pkg_call repo_add "$@"; }
pkg_repo_remove()        { _pkg_call repo_remove "$@"; }
pkg_base_dependencies()  { _pkg_call base_deps; }

# Package version of a Kubernetes version: prereleases use "~" in deb and
# rpm versions (1.38.0-beta.0 is packaged as 1.38.0~beta.0)
_pkg_version_native() { echo "$1" | sed 's/-/~/'; }

# Newest MAJOR.MINOR.PATCH of <minor> among the versions on stdin (one per
# line, release suffix removed). Usage: _pkg_newest_patch <MAJOR.MINOR>
_pkg_newest_patch() {
    awk -v m="$1" 'index($0, m ".") == 1 && $0 ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ {
        split($0, v, "."); if (!n || v[3] + 0 > best) { best = v[3] + 0; n = 1 } }
        END { if (n) print m "." best }'
}

# Replace "name=MAJOR.MINOR" in _PKG_SPECS with the newest patch of that minor
# that <resolver> <name> <minor> finds (unchanged when it finds none), so that
# installs move to the minor in both directions (upgrade and rollback).
_pkg_resolve_minor_specs() {
    local resolver="$1" spec name ver resolved out=""
    for spec in $_PKG_SPECS; do
        name="${spec%%=*}"
        ver="${spec#*=}"
        if [ "$spec" != "$name" ]; then
            case "$ver" in
                *.*.*) ;;
                *.*)
                    resolved=$("$resolver" "$name" "$ver")
                    [ -n "$resolved" ] && spec="${name}=${resolved}"
                    ;;
            esac
        fi
        out="${out}${out:+ }${spec}"
    done
    _PKG_SPECS="$out"
}

# Mirrors fail transiently (metadata being synced): retry before giving up
pkg_refresh() {
    local attempt=1
    until _pkg_call refresh "$@"; do
        if [ "$attempt" -ge 3 ]; then
            return 1
        fi
        log_warn "Refreshing the package indexes failed (attempt ${attempt}/3); retrying in $((attempt * 10))s..."
        sleep $((attempt * 10))
        attempt=$((attempt + 1))
    done
}

pkg_format() {
    case "${DISTRO_PKG:-}" in
        apt)        echo deb ;;
        dnf|zypper) echo rpm ;;
        apk)        echo apk ;;
        pacman)     echo pacman ;;
        *)          echo "" ;;
    esac
}

# Detect the package manager of an unknown system (used for binary installs).
_pkg_detect_manager() {
    if command -v apt-get >/dev/null 2>&1; then echo apt
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then echo dnf
    elif command -v zypper >/dev/null 2>&1; then echo zypper
    elif command -v pacman >/dev/null 2>&1; then echo pacman
    elif command -v apk >/dev/null 2>&1; then echo apk
    fi
}

# Parse pkg_install options. Sets _PKG_HOLD, _PKG_REPO, _PKG_NO_WEAK and
# _PKG_SPECS (space-separated; package specs never contain spaces).
_pkg_parse_install_args() {
    _PKG_HOLD=false
    _PKG_REPO=""
    _PKG_NO_WEAK=false
    _PKG_SPECS=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --hold) _PKG_HOLD=true ;;
            --repo) _PKG_REPO="$2"; shift ;;
            --no-weak-deps) _PKG_NO_WEAK=true ;;
            *) _PKG_SPECS="${_PKG_SPECS}${_PKG_SPECS:+ }$1" ;;
        esac
        shift
    done
}

# Print the package names (without versions) of the parsed specs.
_pkg_spec_names() {
    local _spec _names=""
    for _spec in $_PKG_SPECS; do
        _names="${_names}${_names:+ }${_spec%%=*}"
    done
    echo "$_names"
}

# Print only the installed packages among the given names.
_pkg_filter_installed() {
    local _name _out=""
    for _name in "$@"; do
        if pkg_installed "$_name"; then
            _out="${_out}${_out:+ }${_name}"
        fi
    done
    echo "$_out"
}

# Download a repository signing key with retries.
# Usage: _pkg_fetch_key <url> <output_file>
_pkg_fetch_key() {
    if ! curl -fsSL --retry 8 --retry-delay 5 --retry-all-errors --connect-timeout 10 --max-time 60 \
        -o "$2" "$1"; then
        log_error "Failed to download repository key: $1"
        return 1
    fi
    if [ ! -s "$2" ]; then
        log_error "Repository key is empty: $1"
        return 1
    fi
}
