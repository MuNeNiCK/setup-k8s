#!/bin/sh

# Diagnostics module: collect debug information from nodes on failure.
# Usage: Enable with --collect-diagnostics flag; collected on error paths.

# Collect diagnostic information from a remote node.
# Usage: _collect_diagnostics <user> <host> <output_dir>
_collect_diagnostics() {
    local user="$1" host="$2" output_dir="$3"
    local pfx; pfx=$(_sudo_prefix "$user")

    log_info "Collecting diagnostics from ${host}..."
    mkdir -p "$output_dir" 2>/dev/null || true

    # kubelet logs
    local kubelet_log="${output_dir}/${host}-kubelet.log"
    _deploy_ssh "$user" "$host" "${pfx}journalctl -u kubelet --no-pager -n 100" > "$kubelet_log" 2>/dev/null || true
    [ -s "$kubelet_log" ] && log_info "  Saved kubelet logs: $kubelet_log"

    # containerd logs
    local containerd_log="${output_dir}/${host}-containerd.log"
    _deploy_ssh "$user" "$host" "${pfx}journalctl -u containerd --no-pager -n 50" > "$containerd_log" 2>/dev/null || true
    [ -s "$containerd_log" ] && log_info "  Saved containerd logs: $containerd_log"

    # kubectl events
    local events_log="${output_dir}/${host}-events.log"
    _deploy_ssh "$user" "$host" "${pfx}kubectl --kubeconfig=/etc/kubernetes/admin.conf get events -A --sort-by=.lastTimestamp 2>/dev/null | tail -50" > "$events_log" 2>/dev/null || true
    [ -s "$events_log" ] && log_info "  Saved cluster events: $events_log"

    # Disk and memory
    local system_log="${output_dir}/${host}-system.log"
    {
        echo "=== df -h ==="
        _deploy_ssh "$user" "$host" "df -h" 2>/dev/null || true
        echo ""
        echo "=== free -m ==="
        _deploy_ssh "$user" "$host" "free -m" 2>/dev/null || true
    } > "$system_log" 2>/dev/null || true
    [ -s "$system_log" ] && log_info "  Saved system info: $system_log"

    log_info "  Diagnostics collected for ${host}"
}

# Collect local diagnostic information (for local mode operations).
# Usage: _collect_local_diagnostics <output_dir>
_collect_local_diagnostics() {
    local output_dir="$1"
    local hostname
    hostname=$(hostname 2>/dev/null || echo "localhost")

    log_info "Collecting local diagnostics..."
    mkdir -p "$output_dir" 2>/dev/null || true

    # kubelet logs
    local kubelet_log="${output_dir}/${hostname}-kubelet.log"
    journalctl -u kubelet --no-pager -n 100 > "$kubelet_log" 2>/dev/null || true
    [ -s "$kubelet_log" ] && log_info "  Saved kubelet logs: $kubelet_log"

    # containerd logs
    local containerd_log="${output_dir}/${hostname}-containerd.log"
    journalctl -u containerd --no-pager -n 50 > "$containerd_log" 2>/dev/null || true
    [ -s "$containerd_log" ] && log_info "  Saved containerd logs: $containerd_log"

    # Disk and memory
    local system_log="${output_dir}/${hostname}-system.log"
    {
        echo "=== df -h ==="
        df -h 2>/dev/null || true
        echo ""
        echo "=== free -m ==="
        free -m 2>/dev/null || true
    } > "$system_log" 2>/dev/null || true
    [ -s "$system_log" ] && log_info "  Saved system info: $system_log"

    log_info "  Local diagnostics collected"
}
