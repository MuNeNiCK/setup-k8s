#!/bin/sh

# Shared etcd helpers: container discovery, exec, TLS cert paths,
# binary extraction, and remote transport.
# CLI parsing/help/validation lives in commands/etcd_common.sh.
# Used by commands/backup.sh, commands/restore.sh, and commands/status.sh.

_ETCD_CERT="/etc/kubernetes/pki/etcd/server.crt"
_ETCD_KEY="/etc/kubernetes/pki/etcd/server.key"
_ETCD_CACERT="/etc/kubernetes/pki/etcd/ca.crt"

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

_cleanup_etcd_bundle_dir() {
    [ -n "${_ETCD_BUNDLE_DIR:-}" ] && \
        _deploy_ssh "$_ETCD_REMOTE_USER" "$_ETCD_REMOTE_HOST" "rm -rf '$_ETCD_BUNDLE_DIR'" >/dev/null 2>&1 || true
    _ETCD_BUNDLE_DIR=""
}

# Common setup for remote backup/restore: known_hosts, SSH check
# Sets: _ETCD_REMOTE_USER, _ETCD_REMOTE_HOST
_setup_etcd_remote() {
    local node="$ETCD_CONTROL_PLANES"
    _parse_node_address "$node"
    _ETCD_REMOTE_USER="$_NODE_USER"
    _ETCD_REMOTE_HOST="$_NODE_HOST"

    log_info "Step 1: Checking SSH connectivity..."
    if ! _init_remote_session "etcd" "$node"; then
        return 1
    fi
}

_teardown_etcd_remote() {
    _cleanup_etcd_bundle_dir
    if [ -n "${_ETCD_BUNDLE_DIR_CLEANUP_PUSHED:-}" ]; then
        _pop_cleanup
        _ETCD_BUNDLE_DIR_CLEANUP_PUSHED=""
    fi
    _teardown_session_known_hosts
    _pop_cleanup
    _ETCD_REMOTE_USER=""
    _ETCD_REMOTE_HOST=""
}

# Run a callback with remote etcd setup/teardown orchestration.
# Sets _ETCD_BUNDLE_DIR, _ETCD_REMOTE_BUNDLE_PATH for use by the callback.
# Usage: _with_etcd_remote <label> <callback>
_ETCD_REMOTE_BUNDLE_PATH=""
_with_etcd_remote() {
    local label="$1" callback="$2"

    _setup_etcd_remote || return 1

    log_info "Step 2: Generating and transferring bundle..."
    local bundle_path
    if ! bundle_path=$(_transfer_bundle_to_node "$_ETCD_REMOTE_USER" "$_ETCD_REMOTE_HOST" "etcd"); then
        _teardown_etcd_remote; return 1
    fi
    _ETCD_BUNDLE_DIR=$(dirname "$bundle_path")
    _ETCD_REMOTE_BUNDLE_PATH="$bundle_path"
    _push_cleanup _cleanup_etcd_bundle_dir
    _ETCD_BUNDLE_DIR_CLEANUP_PUSHED=1

    local rc=0
    "$callback" || rc=1

    _teardown_etcd_remote
    return $rc
}

# Build and execute a remote etcd subcommand.
# Uses _deploy_exec_remote directly (not _run_remote_on_node) because
# backup/restore need the remote directory to persist for file downloads.
# Usage: _exec_etcd_remote <subcommand> <label> <bundle_path> <extra_args...>
_exec_etcd_remote() {
    local subcmd="$1" label="$2" bundle_path="$3"; shift 3
    local sudo_pfx; sudo_pfx=$(_sudo_prefix "$_ETCD_REMOTE_USER")
    local cmd="${sudo_pfx}sh ${bundle_path} ${subcmd}"
    for arg in "$@"; do
        cmd="${cmd} $(_posix_shell_quote "$arg")"
    done
    if [ -n "$ETCD_PASSTHROUGH_ARGS" ]; then
        cmd=$(_append_passthrough_to_cmd "$cmd" "$ETCD_PASSTHROUGH_ARGS")
    fi

    if ! _deploy_exec_remote "$_ETCD_REMOTE_USER" "$_ETCD_REMOTE_HOST" "$label" "$cmd"; then
        log_error "Remote ${subcmd} failed"
        return 1
    fi
}
