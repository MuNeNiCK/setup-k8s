#!/bin/sh

# Input validation helpers: CIDR / IP formats, join token formats, option values.

# Parse and validate --distro argument, set DISTRO_OVERRIDE.
# Usage: _parse_distro_arg "$2"
_parse_distro_arg() {
    case "$1" in
        debian|rhel|suse|arch|alpine|generic)
            # shellcheck disable=SC2034 # used by detection.sh after sourcing
            DISTRO_OVERRIDE="$1"
            ;;
        *)
            log_error "--distro must be one of: debian, rhel, suse, arch, alpine, generic (got '$1')"
            exit 1
            ;;
    esac
}

# Validate join token format: 6 lowercase alphanumeric chars, dot, 16 lowercase alphanumeric chars.
# Usage: _validate_join_token_format <token> [label]
_validate_join_token_format() {
    local token="$1" label="${2:---join-token}"
    if ! echo "$token" | grep -qE '^[a-z0-9]{6}\.[a-z0-9]{16}$'; then
        log_error "$label format is invalid (expected: [a-z0-9]{6}.[a-z0-9]{16}, got: $token)"
        return 1
    fi
}

# Validate discovery token hash format: sha256:<64 hex chars>.
# Usage: _validate_discovery_hash_format <hash> [label]
_validate_discovery_hash_format() {
    local hash="$1" label="${2:---discovery-token-hash}"
    if ! echo "$hash" | grep -qE '^sha256:[a-f0-9]{64}$'; then
        log_error "$label format is invalid (expected: sha256:<64 hex chars>, got: $hash)"
        return 1
    fi
}

# Check if an address is IPv6 (contains colon)
_is_ipv6() {
    case "$1" in
        *:*) return 0 ;;
        *) return 1 ;;
    esac
}

# Validate an IPv6 address (no brackets, no CIDR prefix)
_validate_ipv6_addr() {
    local addr="$1" label="$2"
    if ! echo "$addr" | grep -qE '^[a-fA-F0-9:]+$'; then
        log_error "Invalid IPv6 address for $label: $addr"
        exit 1
    fi
}

# Validate an IPv6 CIDR (addr/prefix)
_validate_ipv6_cidr() {
    local cidr="$1" label="$2"
    local addr prefix
    addr="${cidr%/*}"
    prefix="${cidr##*/}"
    if ! echo "$addr" | grep -qE '^[a-fA-F0-9:]+$' || ! echo "$prefix" | grep -qE '^[0-9]+$'; then
        log_error "Invalid IPv6 CIDR for $label: $cidr"
        exit 1
    fi
    if [ "$prefix" -gt 128 ]; then
        log_error "IPv6 prefix length out of range for $label: $cidr (max 128)"
        exit 1
    fi
}

# Validate a single CIDR (IPv4 or IPv6)
_validate_single_cidr() {
    local cidr="$1" label="$2"
    if _is_ipv6 "${cidr%/*}"; then
        _validate_ipv6_cidr "$cidr" "$label"
    else
        # IPv4 CIDR validation
        if ! echo "$cidr" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$'; then
            log_error "Invalid CIDR format for $label: $cidr"
            log_error "Expected format: x.x.x.x/y (e.g., 192.168.0.0/16)"
            exit 1
        fi
        local o1 o2 o3 o4 prefix
        IFS='./' read -r o1 o2 o3 o4 prefix <<EOF
$cidr
EOF
        if [ "$o1" -gt 255 ] || [ "$o2" -gt 255 ] || [ "$o3" -gt 255 ] || [ "$o4" -gt 255 ] || [ "$prefix" -gt 32 ]; then
            log_error "CIDR values out of range for $label: $cidr"
            exit 1
        fi
    fi
}

# Validate CIDR format (IPv4, IPv6, or dual-stack comma-separated)
_validate_cidr() {
    local cidr="$1" label="$2"
    case "$cidr" in
        *,*)
            # Dual-stack: validate each CIDR separately
            local first="${cidr%%,*}"
            local second="${cidr#*,}"
            _validate_single_cidr "$first" "$label (first)"
            _validate_single_cidr "$second" "$label (second)"
            # Ensure one IPv4 + one IPv6
            local first_is_v6=false second_is_v6=false
            _is_ipv6 "${first%/*}" && first_is_v6=true
            _is_ipv6 "${second%/*}" && second_is_v6=true
            if [ "$first_is_v6" = "$second_is_v6" ]; then
                log_error "Dual-stack $label must have one IPv4 and one IPv6 CIDR (got: $cidr)"
                exit 1
            fi
            ;;
        *)
            _validate_single_cidr "$cidr" "$label"
            ;;
    esac
}

# Guard for options requiring a value argument
_require_value() {
    if [ $1 -lt 2 ]; then
        log_error "$2 requires a value"
        exit 1
    fi
    # Reject flag-like values (starting with -) to catch missing arguments
    case "${3:-}" in
        -*)
            log_error "$2 requires a value, got '$3' (looks like a flag)"
            exit 1
            ;;
    esac
}

# Check if an argument is the --distro flag.
_is_distro_flag() { [ "$1" = "--distro" ]; }

# Parse --distro flag: validate and shift.
# Sets DISTRO_FAMILY/DISTRO_OVERRIDE. Caller must shift $_DISTRO_SHIFT.
_DISTRO_SHIFT=0
_parse_distro_flag() {
    _require_value "$1" "$2" "${3:-}"
    _parse_distro_arg "$3"
    _DISTRO_SHIFT=2
}
