#!/bin/sh

# Shared etcd helpers: container discovery, exec, TLS cert paths,
# binary extraction, and remote transport.
# CLI parsing/help/validation lives in commands/etcd.sh.
# Used by commands/etcd.sh, commands/etcd.sh, and commands/status.sh.

_ETCD_CERT="/etc/kubernetes/pki/etcd/server.crt"
_ETCD_KEY="/etc/kubernetes/pki/etcd/server.key"
_ETCD_CACERT="/etc/kubernetes/pki/etcd/ca.crt"
# etcd data directory (a hostPath mount: the same path on the host and in the container)
_ETCD_DATA_DIR="/var/lib/etcd"

# Check whether a crictl container inspect output is the etcd static pod container.
_is_etcd_container_id() {
    local cid="$1"
    local inspect_out
    inspect_out=$(crictl inspect "$cid" 2>/dev/null) || return 1

    echo "$inspect_out" | grep -Eq \
        '"io.kubernetes.container.name"[[:space:]]*:[[:space:]]*"etcd"|"name"[[:space:]]*:[[:space:]]*"etcd"'
}

# Find etcd container ID via crictl
# Returns: container ID on stdout, non-zero on failure
_find_etcd_container() {
    local cid
    cid=$(crictl ps --name=etcd --state=running -q 2>/dev/null | head -1)
    if [ -n "$cid" ] && _is_etcd_container_id "$cid"; then
        echo "$cid"
        return 0
    fi

    local running_ids
    running_ids=$(crictl ps --state=running -q 2>/dev/null) || true
    for cid in $running_ids; do
        if _is_etcd_container_id "$cid"; then
            echo "$cid"
            return 0
        fi
    done

    log_error "etcd container not found (is this a control-plane node?)"
    return 1
}

_resolve_etcd_image_ref() {
    local cid="$1"
    local image_ref=""

    image_ref=$(
        crictl inspect "$cid" 2>/dev/null |
            grep -Eo '"(image|imageRef)"[[:space:]]*:[[:space:]]*"[^"]+"' |
            sed 's/^[^:]*:[[:space:]]*"//; s/"$//' |
            awk '$0 !~ /^sha256:/ { print; exit }'
    ) || true

    if [ -z "$image_ref" ]; then
        image_ref=$(
            ctr -n k8s.io containers info "$cid" 2>/dev/null |
                grep -Eo '"image"[[:space:]]*:[[:space:]]*"[^"]+"' |
                sed 's/^[^:]*:[[:space:]]*"//; s/"$//' |
                head -1
        ) || true
    fi

    if [ -z "$image_ref" ]; then
        image_ref=$(
            crictl inspect "$cid" 2>/dev/null |
                grep -Eo '"(image|imageRef)"[[:space:]]*:[[:space:]]*"[^"]+"' |
                sed 's/^[^:]*:[[:space:]]*"//; s/"$//' |
                head -1
        ) || true
    fi

    [ -n "$image_ref" ] && printf '%s\n' "$image_ref"
}

_containerd_platform() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) printf '%s\n' "linux/amd64" ;;
        aarch64|arm64) printf '%s\n' "linux/arm64" ;;
        armv7l|armv7*) printf '%s\n' "linux/arm/v7" ;;
        armv6l|armv6*) printf '%s\n' "linux/arm/v6" ;;
        ppc64le) printf '%s\n' "linux/ppc64le" ;;
        s390x) printf '%s\n' "linux/s390x" ;;
        *) printf '%s\n' "linux/$arch" ;;
    esac
}

# Run etcdctl inside the etcd container with TLS args
# Usage: _etcdctl_exec <container_id> <etcdctl_args...>
# Check a snapshot file inside the etcd container with etcdutl (bbolt
# consistency check). Prints the number of keys; fails for a damaged or
# empty snapshot. The path must be visible in the container (/var/lib/etcd).
# Usage: _etcd_snapshot_check <container_id> <path>
_etcd_snapshot_check() {
    local cid="$1" path="$2" status keys
    if ! status=$(crictl exec "$cid" etcdutl snapshot status "$path" -w json 2>/dev/null); then
        log_error "The snapshot is damaged (etcdutl snapshot status failed)"
        return 1
    fi
    keys=$(printf '%s\n' "$status" | sed -n 's/.*"totalKey":\([0-9]*\).*/\1/p')
    if [ -z "$keys" ] || [ "$keys" -eq 0 ]; then
        log_error "The snapshot contains no keys: ${status}"
        return 1
    fi
    echo "$keys"
}

_etcdctl_exec() {
    local cid="$1"; shift
    crictl exec "$cid" etcdctl \
        --cacert="$_ETCD_CACERT" \
        --cert="$_ETCD_CERT" \
        --key="$_ETCD_KEY" \
        "$@"
}

# --- Binary extraction ---

# Extract etcd binaries (etcdctl + etcdutl) from the container image.
# Strategy: export image as OCI tar, extract binaries from filesystem layers.
# This avoids depending on shell commands inside the container (distroless images).
# etcdutl is needed for snapshot restore in etcd 3.6+.
# Usage: _extract_etcd_binaries <container_id> <output_dir>
_extract_etcd_binaries() {
    local cid="$1" output_dir="$2"
    log_info "Extracting etcd binaries from container image..."

    local image_ref
    image_ref=$(_resolve_etcd_image_ref "$cid") || true
    if [ -z "$image_ref" ]; then
        log_error "Failed to determine etcd container image ref"
        return 1
    fi

    log_debug "etcd image ref: $image_ref"
    local export_dir
    export_dir=$(mktemp -d /tmp/etcd-export-XXXXXX)

    local image_tar="${export_dir}/image.tar"
    local platform export_err
    platform=$(_containerd_platform)
    if ! export_err=$(ctr -n k8s.io images export --platform "$platform" "$image_tar" "$image_ref" 2>&1 >/dev/null); then
        log_debug "Platform-scoped etcd image export failed ($platform): $export_err"
        rm -f "$image_tar"
        if ! export_err=$(ctr -n k8s.io images export "$image_tar" "$image_ref" 2>&1 >/dev/null); then
            log_error "Failed to export etcd image: $image_ref"
            [ -n "$export_err" ] && log_error "ctr export error: $export_err"
            rm -rf "$export_dir"
            return 1
        fi
    fi

    if [ ! -s "$image_tar" ]; then
        log_error "Failed to export etcd image: $image_ref"
        rm -rf "$export_dir"
        return 1
    fi

    local oci_dir="${export_dir}/oci"
    mkdir -p "$oci_dir"
    tar -xf "$image_tar" -C "$oci_dir" 2>/dev/null || true

    # Search through blobs for layers containing etcd binaries
    local found_etcdctl=false found_etcdutl=false
    local _blob_list
    _blob_list=$(find "$oci_dir/blobs" -type f 2>/dev/null) || true
    for blob in $_blob_list; do
        [ "$found_etcdctl" = true ] && [ "$found_etcdutl" = true ] && break
        local blob_type
        blob_type=$(file -b "$blob" 2>/dev/null) || true
        case "$blob_type" in
            *gzip*|*tar*)
                # Try to list and extract relevant binaries from this layer
                local listing
                listing=$(tar -tzf "$blob" 2>/dev/null || tar -tf "$blob" 2>/dev/null) || continue

                if [ "$found_etcdctl" = false ] && echo "$listing" | grep -q 'usr/local/bin/etcdctl$'; then
                    tar -xzf "$blob" -C "$export_dir" usr/local/bin/etcdctl 2>/dev/null || \
                    tar -xzf "$blob" -C "$export_dir" ./usr/local/bin/etcdctl 2>/dev/null || \
                    tar -xf "$blob" -C "$export_dir" usr/local/bin/etcdctl 2>/dev/null || \
                    tar -xf "$blob" -C "$export_dir" ./usr/local/bin/etcdctl 2>/dev/null || true
                    if [ -f "$export_dir/usr/local/bin/etcdctl" ]; then
                        cp "$export_dir/usr/local/bin/etcdctl" "$output_dir/etcdctl"
                        chmod +x "$output_dir/etcdctl"
                        found_etcdctl=true
                    fi
                fi
                if [ "$found_etcdutl" = false ] && echo "$listing" | grep -q 'usr/local/bin/etcdutl$'; then
                    tar -xzf "$blob" -C "$export_dir" usr/local/bin/etcdutl 2>/dev/null || \
                    tar -xzf "$blob" -C "$export_dir" ./usr/local/bin/etcdutl 2>/dev/null || \
                    tar -xf "$blob" -C "$export_dir" usr/local/bin/etcdutl 2>/dev/null || \
                    tar -xf "$blob" -C "$export_dir" ./usr/local/bin/etcdutl 2>/dev/null || true
                    if [ -f "$export_dir/usr/local/bin/etcdutl" ]; then
                        cp "$export_dir/usr/local/bin/etcdutl" "$output_dir/etcdutl"
                        chmod +x "$output_dir/etcdutl"
                        found_etcdutl=true
                    fi
                fi
                ;;
        esac
    done

    rm -rf "$export_dir"

    if [ "$found_etcdctl" = false ]; then
        log_error "Failed to extract etcdctl from image"
        return 1
    fi
    log_info "etcd binaries extracted to $output_dir (etcdctl: yes, etcdutl: $found_etcdutl)"
    return 0
}

# --- Remote transport helpers ---

# Global state for remote cleanup handlers (closures don't capture locals in sh)
_ETCD_REMOTE_USER=""
_ETCD_REMOTE_HOST=""
_ETCD_BUNDLE_DIR=""

# Run a callback with a remote session on the target control-plane node.
# Sets _ETCD_REMOTE_USER, _ETCD_REMOTE_HOST, and _ETCD_BUNDLE_DIR (the node's
# working directory, used for snapshot transfers) for the callback.
# Usage: _with_etcd_remote <label> <callback>
_with_etcd_remote() {
    local label="$1" callback="$2"
    _parse_node_address "$ETCD_CONTROL_PLANES"
    _ETCD_REMOTE_USER="$_NODE_USER"
    _ETCD_REMOTE_HOST="$_NODE_HOST"

    log_info "Step 1: Checking SSH connectivity and transferring setup-k8s.sh..."
    if ! remote_session_open "$label" "$ETCD_CONTROL_PLANES"; then
        return 1
    fi
    _ETCD_BUNDLE_DIR=$(remote_node_dir "$ETCD_CONTROL_PLANES")

    local rc=0
    "$callback" || rc=1

    remote_session_close
    _ETCD_BUNDLE_DIR=""
    _ETCD_REMOTE_USER=""
    _ETCD_REMOTE_HOST=""
    return $rc
}

# Run a backup/restore subcommand on the target node.
# Usage: _exec_etcd_remote <subcommand> <label> [args...]
_exec_etcd_remote() {
    local subcmd="$1" label="$2"
    shift 2
    if ! remote_run --forward "$ETCD_PASSTHROUGH_ARGS" "$ETCD_CONTROL_PLANES" "$label" "$subcmd" "$@"; then
        log_error "Remote ${subcmd} failed"
        return 1
    fi
}
