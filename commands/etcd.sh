#!/bin/sh

# Shared CLI parsing, help, and validation for backup/restore subcommands.

# Help message for backup/restore (shared).
# Usage: _show_etcd_help <backup|restore>
_show_etcd_help() {
    local mode="$1"
    if [ "$mode" = "backup" ]; then
        echo "Usage: $0 backup [options]"
        echo ""
        echo "Create an etcd snapshot backup from a kubeadm cluster."
        echo ""
        echo "Local mode (run on a control-plane node with sudo):"
        echo "  Optional:"
        echo "    --snapshot-path PATH    Output snapshot path (default: auto-generated)"
    else
        echo "Usage: $0 restore [options]"
        echo ""
        echo "Restore an etcd snapshot to a kubeadm cluster."
        echo ""
        echo "Local mode (run on a control-plane node with sudo):"
        echo "  Required:"
        echo "    --snapshot-path PATH    Snapshot file to restore"
        echo ""
        echo "  Optional:"
    fi
    echo "    --distro FAMILY         Override distro family detection"
    _show_help_footer "    " "Show ${mode} plan and exit"
    echo ""
    echo "Remote mode (from local machine via SSH):"
    echo "  Required:"
    echo "    --control-planes IP     Target control-plane node (user@ip or ip)"
    if [ "$mode" = "restore" ]; then
        echo "    --snapshot-path PATH    Snapshot file to restore (uploaded to remote)"
    fi
    echo ""
    echo "  Optional:"
    if [ "$mode" = "backup" ]; then
        echo "    --snapshot-path PATH    Local download path for snapshot"
    fi
    _show_common_ssh_help "    "
    _show_help_footer "    " "Show ${mode} plan and exit"
    echo ""
    echo "Examples:"
    if [ "$mode" = "backup" ]; then
        echo "  # Local: backup on this node"
        echo "  sudo $0 backup"
        echo "  sudo $0 backup --snapshot-path /tmp/etcd-snapshot.db"
        echo ""
        echo "  # Remote: backup from control-plane node"
        echo "  $0 backup --control-planes 10.0.0.1"
    else
        echo "  # Local: restore on this node"
        echo "  sudo $0 restore --snapshot-path /tmp/etcd-snapshot.db"
        echo ""
        echo "  # Remote: restore to control-plane node"
        echo "  $0 restore --control-planes 10.0.0.1 --snapshot-path /tmp/etcd-snapshot.db"
    fi
}

show_backup_help() { _show_etcd_help "backup"; exit "${1:-0}"; }
show_restore_help() { _show_etcd_help "restore"; exit "${1:-0}"; }

# Parse etcd command line arguments (shared for backup/restore).
# Usage: _parse_etcd_local_args <backup|restore> "$@"
_parse_etcd_local_args() {
    local mode="$1"; shift
    local help_func="show_${mode}_help"
    while [ $# -gt 0 ]; do
        case $1 in
            --help|-h)
                "$help_func"
                ;;
            --snapshot-path)
                _require_value $# "$1" "${2:-}"
                # shellcheck disable=SC2034 # used by backup/restore
                ETCD_SNAPSHOT_PATH="$2"
                shift 2
                ;;
            *)
                if _is_distro_flag "$1"; then
                    _parse_distro_flag $# "$1" "${2:-}"
                    shift "$_DISTRO_SHIFT"
                else
                    log_error "Unknown ${mode} option: $1"
                    "$help_func" 1
                fi
                ;;
        esac
    done
    if [ "$mode" = "backup" ] && [ -z "$ETCD_SNAPSHOT_PATH" ]; then
        ETCD_SNAPSHOT_PATH="/var/lib/etcd-backup/snapshot-$(date +%Y%m%d-%H%M%S).db"
    elif [ "$mode" = "restore" ] && [ -z "$ETCD_SNAPSHOT_PATH" ]; then
        log_error "--snapshot-path is required for restore"
        exit 1
    fi
}

# Usage: _parse_etcd_remote_args <backup|restore> "$@"
_parse_etcd_remote_args() {
    local mode="$1"; shift
    local help_func="show_${mode}_help"
    while [ $# -gt 0 ]; do
        case $1 in
            --help|-h)
                "$help_func"
                ;;
            --control-planes)
                _require_value $# "$1" "${2:-}"
                ETCD_CONTROL_PLANES="$2"
                shift 2
                ;;
            --snapshot-path)
                _require_value $# "$1" "${2:-}"
                ETCD_SNAPSHOT_PATH="$2"
                shift 2
                ;;
            --distro)
                _require_value $# "$1" "${2:-}"
                ETCD_PASSTHROUGH_ARGS=$(_passthrough_add_pair "$ETCD_PASSTHROUGH_ARGS" "$1" "$2")
                shift 2
                ;;
            *)
                if _is_common_ssh_flag "$1"; then
                    _parse_common_ssh_args $# "$1" "${2:-}"
                    shift "$_SSH_SHIFT"
                else
                    log_error "Unknown ${mode} option: $1"
                    "$help_func" 1
                fi
                ;;
        esac
    done
    if [ "$mode" = "backup" ] && [ -z "$ETCD_SNAPSHOT_PATH" ]; then
        ETCD_SNAPSHOT_PATH="./etcd-snapshot-$(date +%Y%m%d-%H%M%S).db"
    elif [ "$mode" = "restore" ] && [ -z "$ETCD_SNAPSHOT_PATH" ]; then
        log_error "--snapshot-path is required for restore"
        exit 1
    fi
}

# Validate etcd remote arguments (shared for backup/restore).
# Usage: _validate_etcd_remote_args <backup|restore>
_validate_etcd_remote_args() {
    local mode="$1"
    ETCD_CONTROL_PLANES=$(_normalize_node_list "$ETCD_CONTROL_PLANES")
    if [ -z "$ETCD_CONTROL_PLANES" ]; then
        log_error "--control-planes is required for remote ${mode}"
        exit 1
    fi
    if [ "$mode" = "restore" ] && [ ! -f "$ETCD_SNAPSHOT_PATH" ]; then
        log_error "Snapshot file not found: $ETCD_SNAPSHOT_PATH"
        exit 1
    fi
    _validate_common_ssh_args
    _validate_node_addresses "$ETCD_CONTROL_PLANES"
}

# Public wrappers (called by setup-k8s.sh)
parse_backup_local_args() { _parse_etcd_local_args "backup" "$@"; }
parse_restore_local_args() { _parse_etcd_local_args "restore" "$@"; }
parse_backup_remote_args() { _parse_etcd_remote_args "backup" "$@"; }
parse_restore_remote_args() { _parse_etcd_remote_args "restore" "$@"; }
validate_backup_remote_args() { _validate_etcd_remote_args "backup"; }
validate_restore_remote_args() { _validate_etcd_remote_args "restore"; }

# ============================================================
# backup subcommand
# ============================================================

# Etcd backup module: create etcd snapshots locally or via SSH.
# Shared helpers (container discovery, remote transport, CLI parsing) → lib/cluster/etcd.sh

# --- Local backup ---

backup_etcd_local() {
    _audit_log "backup" "started" "path=${ETCD_SNAPSHOT_PATH}"
    log_info "Starting etcd backup..."

    # Find etcd container
    local cid
    if ! cid=$(_find_etcd_container); then
        _audit_log "backup" "failed" "reason=etcd_container_not_found"
        return 1
    fi

    # Create output directory
    local snapshot_dir
    snapshot_dir=$(dirname "$ETCD_SNAPSHOT_PATH")
    if [ ! -d "$snapshot_dir" ]; then
        mkdir -p "$snapshot_dir"
    fi

    # Save snapshot inside the container
    local container_snapshot="${_ETCD_DATA_DIR}/snapshot-tmp-$$.db"
    log_info "Creating etcd snapshot..."
    if ! _etcdctl_exec "$cid" snapshot save "$container_snapshot"; then
        log_error "etcdctl snapshot save failed"
        _audit_log "backup" "failed" "reason=etcdctl_snapshot_save_failed"
        return 1
    fi

    # Check the snapshot while it is visible in the container
    local snapshot_keys
    if ! snapshot_keys=$(_etcd_snapshot_check "$cid" "$container_snapshot"); then
        rm -f "$container_snapshot" >/dev/null 2>&1 || true
        _audit_log "backup" "failed" "reason=snapshot_invalid"
        return 1
    fi

    # Copy snapshot from the host side of the data directory mount
    log_info "Copying snapshot to $ETCD_SNAPSHOT_PATH..."
    if ! cp "$container_snapshot" "$ETCD_SNAPSHOT_PATH"; then
        log_error "Failed to copy snapshot from $container_snapshot"
        _audit_log "backup" "failed" "reason=snapshot_copy_failed"
        return 1
    fi

    # The copy must be identical to the checked snapshot
    if [ "$(sha256sum < "$container_snapshot")" != "$(sha256sum < "$ETCD_SNAPSHOT_PATH")" ]; then
        log_error "The copied snapshot differs from the checked one"
        rm -f "$container_snapshot" >/dev/null 2>&1 || true
        _audit_log "backup" "failed" "reason=snapshot_copy_mismatch"
        return 1
    fi
    rm -f "$container_snapshot" >/dev/null 2>&1 || true

    local snapshot_size
    snapshot_size=$(wc -c < "$ETCD_SNAPSHOT_PATH")
    _audit_log "backup" "completed" "path=${ETCD_SNAPSHOT_PATH} size=${snapshot_size} keys=${snapshot_keys}"
    log_info "Etcd backup complete: $ETCD_SNAPSHOT_PATH ($snapshot_size bytes, ${snapshot_keys} keys)"
    return 0
}

# --- Dry-run ---

backup_dry_run() {
    log_info "=== Backup Dry-Run Plan ==="
    log_info ""

    if [ -n "$ETCD_CONTROL_PLANES" ]; then
        log_info "Mode: Remote"
        log_info "Target Node: $ETCD_CONTROL_PLANES"
        log_info ""
        _log_ssh_settings
        log_info ""
        log_info "Orchestration Plan:"
        log_info "  1. Check SSH connectivity"
        log_info "  2. Generate and transfer bundle"
        log_info "  3. Execute backup on remote node"
        log_info "  4. Download snapshot to: $ETCD_SNAPSHOT_PATH"
    else
        log_info "Mode: Local"
        log_info "Snapshot Output: $ETCD_SNAPSHOT_PATH"
        log_info ""
        log_info "Steps:"
        log_info "  1. Find etcd container via crictl"
        log_info "  2. Run etcdctl snapshot save inside container"
        log_info "  3. Copy snapshot to host"
        log_info "  4. Verify snapshot"
    fi
    log_info ""
    log_info "=== End of dry-run (no changes made) ==="
}

# --- Remote backup ---

_backup_etcd_remote_callback() {
    local remote_snapshot="${_ETCD_BUNDLE_DIR}/etcd-snapshot.db"

    log_info "Step 2: Executing backup on remote node..."
    if ! _exec_etcd_remote "backup" "etcd backup" --snapshot-path "$remote_snapshot"; then
        return 1
    fi

    log_info "Step 3: Downloading snapshot to $ETCD_SNAPSHOT_PATH..."
    if [ "$_ETCD_REMOTE_USER" != "root" ]; then
        _deploy_ssh "$_ETCD_REMOTE_USER" "$_ETCD_REMOTE_HOST" "sudo -n chmod 644 '${remote_snapshot}'" >/dev/null 2>&1 || true
    fi
    if ! _deploy_scp_from "$_ETCD_REMOTE_USER" "$_ETCD_REMOTE_HOST" "$remote_snapshot" "$ETCD_SNAPSHOT_PATH"; then
        log_error "Failed to download snapshot"
        return 1
    fi

    # The node checked its snapshot; the download must be identical
    local remote_sum local_sum
    remote_sum=$(_deploy_ssh "$_ETCD_REMOTE_USER" "$_ETCD_REMOTE_HOST" "sha256sum '${remote_snapshot}'" 2>/dev/null | awk '{print $1}') || remote_sum=""
    local_sum=$(sha256sum "$ETCD_SNAPSHOT_PATH" | awk '{print $1}')
    if [ -z "$remote_sum" ] || [ "$remote_sum" != "$local_sum" ]; then
        log_error "The downloaded snapshot differs from the one on the node (sha256 ${local_sum} vs ${remote_sum:-unknown})"
        return 1
    fi
    log_info "Snapshot downloaded: $ETCD_SNAPSHOT_PATH ($(wc -c < "$ETCD_SNAPSHOT_PATH") bytes, sha256 ${local_sum})"
}

backup_etcd_remote() {
    log_info "Remote etcd backup from ${ETCD_CONTROL_PLANES}..."
    _with_etcd_remote "backup" _backup_etcd_remote_callback
    local rc=$?
    [ $rc -eq 0 ] && log_info "Remote etcd backup complete!"
    return $rc
}

# ============================================================
# restore subcommand
# ============================================================

# Etcd restore module: restore etcd snapshots locally or via SSH.
# Shared helpers (container discovery, remote transport, CLI parsing) → lib/cluster/etcd.sh

# --- Local restore ---

# Cleanup handler for etcd manifest restore (uses fixed paths, not local variables)
_ETCD_MANIFEST_TMP_DIR="/tmp/setup-k8s-restore-manifests"
_ETCD_CONTAINER_RESTORE_NAME="setup-k8s-restore-data"
_ETCD_CONTAINER_SNAPSHOT_NAME="setup-k8s-restore-snapshot.db"
_ETCD_PREPARED_RESTORE_DIR=""

_restore_control_plane_manifests() {
    local name src dst
    for name in etcd kube-apiserver kube-controller-manager kube-scheduler; do
        src="${_ETCD_MANIFEST_TMP_DIR}/${name}.yaml"
        dst="/etc/kubernetes/manifests/${name}.yaml"
        if [ -f "$src" ] && [ ! -f "$dst" ]; then
            log_warn "Restoring ${name} manifest from backup..."
            mv "$src" "$dst"
        fi
    done
    rmdir "$_ETCD_MANIFEST_TMP_DIR" 2>/dev/null || true
}

_move_control_plane_manifest() {
    local name="$1"
    local src="/etc/kubernetes/manifests/${name}.yaml"
    local dst="${_ETCD_MANIFEST_TMP_DIR}/${name}.yaml"
    if [ -f "$src" ]; then
        mv "$src" "$dst"
    fi
}

_wait_static_pod_container_stopped() {
    local name="$1" timeout="${2:-60}" elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        if ! crictl ps --name="$name" --state=running -q 2>/dev/null | grep -q .; then
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1
}

_prepare_etcd_restore_with_container_binary() {
    local cid="$1" snapshot_path="$2" etcd_data_dir="$3"
    local container_snapshot="${etcd_data_dir}/${_ETCD_CONTAINER_SNAPSHOT_NAME}"
    local container_restore_dir="${etcd_data_dir}/${_ETCD_CONTAINER_RESTORE_NAME}"

    _ETCD_PREPARED_RESTORE_DIR=""
    rm -rf "$container_restore_dir" "$container_snapshot"
    if ! cp "$snapshot_path" "$container_snapshot"; then
        log_error "Failed to stage snapshot for container-based restore"
        return 1
    fi

    local restore_ok=false
    log_info "Trying etcdutl inside the running etcd container"
    if crictl exec "$cid" etcdutl snapshot restore "$container_snapshot" \
        --data-dir "$container_restore_dir"; then
        restore_ok=true
    fi

    if [ "$restore_ok" = false ]; then
        log_info "Trying etcdctl inside the running etcd container"
        if crictl exec "$cid" etcdctl snapshot restore "$container_snapshot" \
            --data-dir "$container_restore_dir"; then
            restore_ok=true
        fi
    fi

    rm -f "$container_snapshot"
    if [ "$restore_ok" = false ] || [ ! -d "$container_restore_dir" ]; then
        log_error "Container-based snapshot restore preparation failed"
        rm -rf "$container_restore_dir"
        return 1
    fi

    _ETCD_PREPARED_RESTORE_DIR="$container_restore_dir"
    return 0
}

restore_etcd_local() {
    _audit_log "restore" "started" "path=${ETCD_SNAPSHOT_PATH}"
    log_info "Starting etcd restore from $ETCD_SNAPSHOT_PATH..."

    # Validate snapshot file
    if [ ! -f "$ETCD_SNAPSHOT_PATH" ]; then
        log_error "Snapshot file not found: $ETCD_SNAPSHOT_PATH"
        _audit_log "restore" "failed" "reason=snapshot_not_found path=${ETCD_SNAPSHOT_PATH}"
        return 1
    fi

    local etcd_data_dir="$_ETCD_DATA_DIR"
    local use_prepared_restore=false

    # Find etcd container and prepare restore tooling before stopping
    local cid
    local etcd_bin_dir
    etcd_bin_dir=$(mktemp -d /tmp/etcd-restore-bin-XXXXXX)
    if ! cid=$(_find_etcd_container); then
        _audit_log "restore" "failed" "reason=etcd_container_not_found"
        rm -rf "$etcd_bin_dir"; return 1
    fi
    if ! _extract_etcd_binaries "$cid" "$etcd_bin_dir"; then
        log_warn "Falling back to container-based snapshot restore preparation"
        if _prepare_etcd_restore_with_container_binary "$cid" "$ETCD_SNAPSHOT_PATH" "$etcd_data_dir"; then
            use_prepared_restore=true
        else
            _audit_log "restore" "failed" "reason=binary_extraction_failed"
            rm -rf "$etcd_bin_dir"; return 1
        fi
    fi

    # Move static pod manifests to stop API writers and etcd before restoring data.
    if [ ! -f "$_ETCD_MANIFEST_PATH" ]; then
        log_error "etcd manifest not found: $_ETCD_MANIFEST_PATH"
        _audit_log "restore" "failed" "reason=etcd_manifest_not_found"
        return 1
    fi

    rm -rf "$_ETCD_MANIFEST_TMP_DIR"
    mkdir -p "$_ETCD_MANIFEST_TMP_DIR"
    _push_cleanup _restore_control_plane_manifests

    log_info "Stopping Kubernetes control-plane static pods..."
    _move_control_plane_manifest kube-apiserver
    _move_control_plane_manifest kube-controller-manager
    _move_control_plane_manifest kube-scheduler

    local component
    for component in kube-apiserver kube-controller-manager kube-scheduler; do
        if ! _wait_static_pod_container_stopped "$component" 60; then
            log_error "Timeout waiting for ${component} container to stop"
            _audit_log "restore" "failed" "reason=${component}_stop_timeout"
            return 1
        fi
    done

    log_info "Moving etcd manifest to stop etcd container..."
    _move_control_plane_manifest etcd

    # Wait for etcd container to stop
    log_info "Waiting for etcd container to stop..."
    local wait_elapsed=0 wait_timeout=60
    while [ $wait_elapsed -lt $wait_timeout ]; do
        if ! _find_etcd_container >/dev/null 2>&1; then
            break
        fi
        sleep 2
        wait_elapsed=$((wait_elapsed + 2))
    done
    if [ $wait_elapsed -ge $wait_timeout ]; then
        log_error "Timeout waiting for etcd container to stop"
        _audit_log "restore" "failed" "reason=etcd_stop_timeout"
        return 1
    fi
    log_info "etcd container stopped"

    # Backup existing data directory
    if [ -d "$etcd_data_dir" ]; then
        local backup_dir
        backup_dir="${etcd_data_dir}.bak.$(date +%Y%m%d-%H%M%S)"
        log_info "Backing up existing etcd data to $backup_dir..."
        mv "$etcd_data_dir" "$backup_dir"
    fi

    # Restore snapshot — use etcdutl for etcd 3.6+ (etcdctl snapshot restore was removed)
    log_info "Restoring etcd snapshot..."
    local restore_ok=false
    if [ "$use_prepared_restore" = true ]; then
        local prepared_restore_dir="$_ETCD_PREPARED_RESTORE_DIR"
        if [ -n "${backup_dir:-}" ]; then
            prepared_restore_dir="${backup_dir}/${_ETCD_CONTAINER_RESTORE_NAME}"
        fi
        if [ -d "$prepared_restore_dir" ]; then
            mv "$prepared_restore_dir" "$etcd_data_dir"
            restore_ok=true
        fi
    elif [ -x "$etcd_bin_dir/etcdutl" ]; then
        log_info "Using etcdutl for snapshot restore"
        if "$etcd_bin_dir/etcdutl" snapshot restore "$ETCD_SNAPSHOT_PATH" \
            --data-dir "$etcd_data_dir"; then
            restore_ok=true
        fi
    fi

    # Fallback to etcdctl (etcd 3.5 and earlier)
    if [ "$restore_ok" = false ] && [ -x "$etcd_bin_dir/etcdctl" ]; then
        log_info "Trying etcdctl for snapshot restore"
        if "$etcd_bin_dir/etcdctl" snapshot restore "$ETCD_SNAPSHOT_PATH" \
            --data-dir "$etcd_data_dir"; then
            restore_ok=true
        fi
    fi

    if [ "$restore_ok" = false ]; then
        log_error "Snapshot restore failed"
        _audit_log "restore" "failed" "reason=snapshot_restore_failed"
        # Restore original data directory if backup exists
        if [ -n "${backup_dir:-}" ] && [ -d "$backup_dir" ]; then
            log_warn "Restoring original etcd data from $backup_dir..."
            rm -rf "$etcd_data_dir" 2>/dev/null || true
            mv "$backup_dir" "$etcd_data_dir"
        fi
        rm -rf "$etcd_bin_dir"
        return 1
    fi
    log_info "Snapshot restored to $etcd_data_dir"

    # Restore etcd manifest first so storage is healthy before API components start.
    log_info "Restoring etcd manifest to start etcd..."
    mv "${_ETCD_MANIFEST_TMP_DIR}/etcd.yaml" "$_ETCD_MANIFEST_PATH"

    # Wait for etcd to start and become healthy
    log_info "Waiting for etcd to start..."
    local start_elapsed=0 start_timeout=120
    while [ $start_elapsed -lt $start_timeout ]; do
        local new_cid
        new_cid=$(_find_etcd_container 2>/dev/null) || true
        if [ -n "$new_cid" ]; then
            # Health check
            if _etcdctl_exec "$new_cid" endpoint health >/dev/null 2>&1; then
                log_info "etcd is healthy"
                break
            fi
        fi
        sleep 3
        start_elapsed=$((start_elapsed + 3))
    done

    if [ $start_elapsed -ge $start_timeout ]; then
        log_error "Timeout waiting for etcd health check after ${start_timeout}s"
        _audit_log "restore" "failed" "reason=etcd_health_timeout"
        rm -rf "$etcd_bin_dir"
        return 1
    fi

    log_info "Restoring Kubernetes control-plane manifests..."
    _restore_control_plane_manifests
    _pop_cleanup

    # Clean up
    rm -rf "$etcd_bin_dir"

    # The restore is complete when the API server serves the restored data
    log_info "Waiting for the API server..."
    local api_elapsed=0 api_timeout=180
    until kubectl --kubeconfig=/etc/kubernetes/admin.conf get --raw /readyz >/dev/null 2>&1; do
        if [ "$api_elapsed" -ge "$api_timeout" ]; then
            log_error "The API server did not become ready within ${api_timeout}s after the restore"
            _audit_log "restore" "failed" "reason=apiserver_not_ready"
            return 1
        fi
        sleep 3
        api_elapsed=$((api_elapsed + 3))
    done
    log_info "API server is ready"

    _audit_log "restore" "completed" "path=${ETCD_SNAPSHOT_PATH}"
    log_info "Etcd restore complete!"
    return 0
}

# --- Dry-run ---

restore_dry_run() {
    log_info "=== Restore Dry-Run Plan ==="
    log_info ""

    if [ -n "$ETCD_CONTROL_PLANES" ]; then
        log_info "Mode: Remote"
        log_info "Target Node: $ETCD_CONTROL_PLANES"
        log_info "Snapshot: $ETCD_SNAPSHOT_PATH"
        log_info ""
        _log_ssh_settings
        log_info ""
        log_info "Orchestration Plan:"
        log_info "  1. Check SSH connectivity"
        log_info "  2. Upload snapshot to remote node"
        log_info "  3. Generate and transfer bundle"
        log_info "  4. Execute restore on remote node"
    else
        log_info "Mode: Local"
        log_info "Snapshot: $ETCD_SNAPSHOT_PATH"
        log_info ""
        log_info "Steps:"
        log_info "  1. Find etcd container, extract etcdctl binary"
        log_info "  2. Stop etcd (move static pod manifest)"
        log_info "  3. Backup existing etcd data directory"
        log_info "  4. Run etcdctl snapshot restore"
        log_info "  5. Restore etcd manifest, wait for etcd to start"
        log_info "  6. Verify etcd health"
    fi
    log_info ""
    log_info "=== End of dry-run (no changes made) ==="
}

# --- Remote restore ---

_restore_etcd_remote_callback() {
    local remote_snapshot="${_ETCD_BUNDLE_DIR}/etcd-snapshot.db"

    log_info "Step 2: Uploading snapshot to remote node..."
    if ! _deploy_scp "$ETCD_SNAPSHOT_PATH" "$_ETCD_REMOTE_USER" "$_ETCD_REMOTE_HOST" "$remote_snapshot"; then
        log_error "Failed to upload snapshot"
        return 1
    fi

    log_info "Step 3: Executing restore on remote node..."
    if ! _exec_etcd_remote "restore" "etcd restore" --snapshot-path "$remote_snapshot"; then
        return 1
    fi
}

restore_etcd_remote() {
    log_info "Remote etcd restore to ${ETCD_CONTROL_PLANES}..."
    _with_etcd_remote "restore" _restore_etcd_remote_callback
    local rc=$?
    [ $rc -eq 0 ] && log_info "Remote etcd restore complete!"
    return $rc
}

# === Runner ===

_backup_local_main() { backup_etcd_local; }

_restore_local_main() { restore_etcd_local; }

_run_etcd() {
    if [ "$ACTION" = "backup" ]; then
        _run_dual_mode backup \
            parse_backup_remote_args validate_backup_remote_args backup_dry_run backup_etcd_remote \
            "Local backup" parse_backup_local_args backup_dry_run _backup_local_main \
            "$@"
    else
        _run_dual_mode restore \
            parse_restore_remote_args validate_restore_remote_args restore_dry_run restore_etcd_remote \
            "Local restore" parse_restore_local_args restore_dry_run _restore_local_main \
            "$@"
    fi
}
