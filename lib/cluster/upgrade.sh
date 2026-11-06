#!/bin/sh

# Upgrade helpers: version utilities and node role detection.
# Used by commands/upgrade.sh for both local and remote upgrade operations.

# Get current kubeadm version as MAJOR.MINOR.PATCH
_get_current_k8s_version() {
    kubeadm version -o short | sed 's/^v//'
}

# Validate upgrade version constraints
# - No downgrade
# - No minor version skip (target minor <= current minor + 1)
# - Target must differ from current
_validate_upgrade_version() {
    local current="$1" target="$2"

    # Validate MAJOR.MINOR.PATCH format
    if ! echo "$current" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
        log_error "Invalid current version format: '${current}' (expected MAJOR.MINOR.PATCH)"
        return 1
    fi
    if ! echo "$target" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
        log_error "Invalid target version format: '${target}' (expected MAJOR.MINOR.PATCH)"
        return 1
    fi

    local cur_major cur_minor cur_patch tar_major tar_minor tar_patch
    cur_major=$(echo "$current" | cut -d. -f1)
    cur_minor=$(echo "$current" | cut -d. -f2)
    cur_patch=$(echo "$current" | cut -d. -f3)
    tar_major=$(echo "$target" | cut -d. -f1)
    tar_minor=$(echo "$target" | cut -d. -f2)
    tar_patch=$(echo "$target" | cut -d. -f3)

    # Same version
    if [ "$cur_major" -eq "$tar_major" ] && [ "$cur_minor" -eq "$tar_minor" ] && [ "$cur_patch" -eq "$tar_patch" ]; then
        log_error "Current version ($current) is already at target version ($target)"
        return 1
    fi

    # Downgrade check
    if [ "$tar_major" -lt "$cur_major" ]; then
        log_error "Downgrade not supported: $current -> $target"
        return 1
    fi
    if [ "$tar_major" -eq "$cur_major" ] && [ "$tar_minor" -lt "$cur_minor" ]; then
        log_error "Downgrade not supported: $current -> $target"
        return 1
    fi
    if [ "$tar_major" -eq "$cur_major" ] && [ "$tar_minor" -eq "$cur_minor" ] && [ "$tar_patch" -lt "$cur_patch" ]; then
        log_error "Downgrade not supported: $current -> $target"
        return 1
    fi

    # Minor version skip check (only +1 minor allowed)
    if [ "$tar_major" -eq "$cur_major" ] && [ "$tar_minor" -gt $((cur_minor + 1)) ]; then
        log_error "Cannot skip minor versions: $current -> $target (max +1 minor version at a time)"
        return 1
    fi

    # Major version jump
    if [ "$tar_major" -gt "$cur_major" ]; then
        log_error "Major version upgrade not supported: $current -> $target"
        return 1
    fi

    return 0
}

# --- Multi-Version Step Computation ---

# Compute intermediate upgrade steps for auto-step-upgrade.
# Fetches the latest patch version for each intermediate minor from dl.k8s.io.
# Output: newline-separated list of versions (MAJOR.MINOR.PATCH), one per line.
# Usage: _compute_upgrade_steps <current_version> <target_version>
_compute_upgrade_steps() {
    local current="$1" target="$2"
    local cur_minor tar_minor
    cur_minor=$(echo "$current" | cut -d. -f2)
    tar_minor=$(echo "$target" | cut -d. -f2)
    local major
    major=$(echo "$current" | cut -d. -f1)

    local steps=""
    local m=$((cur_minor + 1))
    while [ "$m" -lt "$tar_minor" ]; do
        local latest
        latest=$(curl -fsSL --retry 2 --max-time 10 "https://dl.k8s.io/release/stable-${major}.${m}.txt" 2>/dev/null | sed 's/^v//') || true
        if [ -z "$latest" ]; then
            log_error "Failed to fetch latest patch version for ${major}.${m}.x from dl.k8s.io"
            return 1
        fi
        steps="${steps}${steps:+
}${latest}"
        m=$((m + 1))
    done
    # Final target
    steps="${steps}${steps:+
}${target}"
    echo "$steps"
}

# --- Node Role Detection ---

# Detect whether this node is a control-plane or worker
_detect_node_role() {
    if [ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]; then
        if [ "$UPGRADE_FIRST_CONTROL_PLANE" = true ]; then
            echo "first-control-plane"
        else
            echo "control-plane"
        fi
    else
        echo "worker"
    fi
}

# --- Rollback helpers ---

# Record pre-upgrade package versions from a remote node.
# Sets _PRE_UPGRADE_VERSION with the current kubeadm version.
# Usage: _record_pre_upgrade_versions <user> <host>
_record_pre_upgrade_versions() {
    local user="$1" host="$2"
    local pfx; pfx=$(_sudo_prefix "$user")

    _PRE_UPGRADE_VERSION=""
    _PRE_UPGRADE_VERSION=$(_deploy_ssh "$user" "$host" "${pfx}kubeadm version -o short" 2>/dev/null | sed 's/^v//' | tr -d '[:space:]') || true
    if [ -n "$_PRE_UPGRADE_VERSION" ]; then
        log_debug "  [${host}] Pre-upgrade version: v${_PRE_UPGRADE_VERSION}"
    fi
}

# Roll a failed node back to the pre-upgrade package versions.
# The node runs "upgrade --rollback-to <version>", which reinstalls kubeadm,
# kubelet, and kubectl at that version and restarts kubelet.
# Usage: _rollback_node <node> <pre_version>
_rollback_node() {
    local node="$1" pre_version="$2"
    _parse_node_address "$node"
    local host="$_NODE_HOST"

    if [ -z "$pre_version" ]; then
        log_warn "  [${host}] No pre-upgrade version recorded, cannot rollback"
        return 1
    fi

    log_warn "  [${host}] Attempting rollback to v${pre_version}..."
    if remote_run --forward "$UPGRADE_PASSTHROUGH_ARGS" --drop "--kubernetes-version --skip-drain" \
        "$node" "rollback" upgrade --rollback-to "$pre_version"; then
        log_info "  [${host}] Rollback to v${pre_version} succeeded"
        return 0
    fi
    log_error "  [${host}] Rollback failed. Manual intervention required."
    return 1
}

# ============================================================
# Remote upgrade orchestration
# ============================================================

# Remote upgrade orchestration: multi-node upgrade via SSH.
# Local upgrade logic -> commands/upgrade.sh
# Version helpers, rollback -> lib/cluster/upgrade.sh

# Helper: drain a node
_upgrade_drain_node() {
    local user="$1" host="$2" node_name="$3"
    local pfx; pfx=$(_sudo_prefix "$user")
    log_info "  [${node_name}] Draining node..."
    if ! _deploy_ssh "$user" "$host" "${pfx}kubectl --kubeconfig=/etc/kubernetes/admin.conf drain '$node_name' --ignore-daemonsets --delete-emptydir-data --timeout=300s"; then
        log_error "  [${node_name}] Drain failed"
        return 1
    fi
    log_info "  [${node_name}] Node drained"
}

# Helper: uncordon a node
_upgrade_uncordon_node() {
    local user="$1" host="$2" node_name="$3" attempt=1
    local pfx; pfx=$(_sudo_prefix "$user")
    log_info "  [${node_name}] Uncordoning node..."
    # The API server may be restarting right after a control-plane upgrade
    until _deploy_ssh "$user" "$host" "${pfx}kubectl --kubeconfig=/etc/kubernetes/admin.conf uncordon '$node_name'"; do
        if [ "$attempt" -ge 5 ]; then
            log_error "  [${node_name}] Uncordon failed"
            return 1
        fi
        attempt=$((attempt + 1))
        sleep 5
    done
    log_info "  [${node_name}] Node uncordoned"
}

# Wait until the API server reports <version> (after "kubeadm upgrade apply").
# Usage: _upgrade_verify_api_version <cp_user> <cp_host> <version>
_upgrade_verify_api_version() {
    local user="$1" host="$2" version="$3"
    local pfx; pfx=$(_sudo_prefix "$user")
    local got="" elapsed=0
    while [ "$elapsed" -le 120 ]; do
        got=$(_deploy_ssh "$user" "$host" "${pfx}kubectl --kubeconfig=/etc/kubernetes/admin.conf version -o json" 2>/dev/null \
            | awk -F'"' '/"serverVersion"/ {s = 1} s && /"gitVersion"/ {print $4; exit}') || got=""
        if [ "$got" = "v${version}" ]; then
            log_info "  API server reports v${version}"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    log_error "  API server reports ${got:-no version} (expected v${version})"
    return 1
}

# Wait until the cluster reports the node's kubelet at <version>.
# Usage: _upgrade_verify_node_version <cp_user> <cp_host> <node_name> <version>
_upgrade_verify_node_version() {
    local user="$1" host="$2" node_name="$3" version="$4"
    local pfx; pfx=$(_sudo_prefix "$user")
    local got="" elapsed=0
    while [ "$elapsed" -le 120 ]; do
        got=$(_deploy_ssh "$user" "$host" "${pfx}kubectl --kubeconfig=/etc/kubernetes/admin.conf get node '$node_name' -o jsonpath='{.status.nodeInfo.kubeletVersion}'" 2>/dev/null) || got=""
        if [ "$got" = "v${version}" ]; then
            log_info "  [${node_name}] kubelet reports v${version}"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    log_error "  [${node_name}] kubelet reports ${got:-no version} (expected v${version})"
    return 1
}

# Upgrade a single node: resolve, drain, execute, uncordon, rollback on error.
# Usage: _upgrade_single_node <node_csv_entry> <state_label> <is_first_cp> [pre_hook] [post_hook]
# Requires: cp1_user, cp1_host (set by upgrade_cluster before calling)
_upgrade_single_node() {
    local node="$1" state_label="$2" is_first_cp="$3"
    local pre_hook="${4:-}" post_hook="${5:-}"

    _parse_node_address "$node"
    local node_user="$_NODE_USER" node_host="$_NODE_HOST"

    if _state_is_step_done "${state_label}_${node_host}"; then
        log_info "  [${node_host}] ${state_label} upgrade... (skipped, resumed)"
        return 0
    fi

    local node_sudo; node_sudo=$(_sudo_prefix "$node_user")

    local node_name
    if ! node_name=$(_get_node_name "$cp1_user" "$cp1_host" "$node_host"); then
        log_error "Could not find the Kubernetes node of ${node_host} (by address or hostname)"
        return 1
    fi

    _record_pre_upgrade_versions "$node_user" "$node_host"

    if [ "$UPGRADE_SKIP_DRAIN" != true ]; then
        if ! _upgrade_drain_node "$cp1_user" "$cp1_host" "$node_name"; then
            log_error "Drain failed for ${node_host}."
            return 1
        fi
    fi

    # Pre-hook (e.g., worker admin.conf transfer)
    local _hook_data=""
    if [ -n "$pre_hook" ]; then
        if ! _hook_data=$("$pre_hook" "$node_user" "$node_host" "$node_sudo"); then
            return 1
        fi
    fi

    # Remote command: upgrade --kubernetes-version <target> [--first-control-plane] [forwarded args]
    set -- upgrade --kubernetes-version "$UPGRADE_TARGET_VERSION"
    if [ "$is_first_cp" = true ]; then
        set -- "$@" --first-control-plane
    fi
    if [ -n "${KUBEADM_PATCHES_DIR:-}" ]; then
        set -- "$@" --kubeadm-patches "$(remote_node_dir "$node")/kubeadm-patches"
    fi
    local upgrade_rc=0
    if [ -n "$_hook_data" ]; then
        remote_run --env "UPGRADE_ADMIN_CONF=${_hook_data}" --forward "$UPGRADE_PASSTHROUGH_ARGS" \
            --drop "--kubernetes-version --skip-drain" "$node" "upgrade ${state_label}" "$@" || upgrade_rc=1
    else
        remote_run --forward "$UPGRADE_PASSTHROUGH_ARGS" \
            --drop "--kubernetes-version --skip-drain" "$node" "upgrade ${state_label}" "$@" || upgrade_rc=1
    fi

    if [ "$upgrade_rc" -ne 0 ]; then
        log_error "Upgrade failed for ${node_host}."
        if [ "${COLLECT_DIAGNOSTICS:-false}" = true ]; then
            _collect_diagnostics "$node_user" "$node_host" "/tmp/setup-k8s-diag-upgrade-${state_label}-$(date +%s)" || true
        fi
        [ -n "$post_hook" ] && "$post_hook" "$node_user" "$node_host" "$node_sudo" "${_hook_data}" "cleanup" || true
        if [ "$UPGRADE_NO_ROLLBACK" != true ] && [ -n "${_PRE_UPGRADE_VERSION:-}" ]; then
            _rollback_node "$node" "$_PRE_UPGRADE_VERSION" || true
            [ "$UPGRADE_SKIP_DRAIN" != true ] && _upgrade_uncordon_node "$cp1_user" "$cp1_host" "$node_name" || true
        fi
        return 1
    fi

    [ -n "$post_hook" ] && "$post_hook" "$node_user" "$node_host" "$node_sudo" "${_hook_data}" "success" || true

    if ! _upgrade_verify_node_version "$cp1_user" "$cp1_host" "$node_name" "$UPGRADE_TARGET_VERSION"; then
        return 1
    fi

    if [ "$UPGRADE_SKIP_DRAIN" != true ]; then
        if ! _upgrade_uncordon_node "$cp1_user" "$cp1_host" "$node_name"; then
            log_error "${node_host} was upgraded but stays cordoned (SchedulingDisabled)."
            log_error "  Run: kubectl uncordon ${node_name}"
            return 1
        fi
    fi

    _state_mark_step "${state_label}_${node_host}" "done"
    log_info "  [${node_host}] ${state_label} upgrade complete"
}

# Worker pre-hook: transfer admin.conf from CP to worker node.
# Outputs remote admin.conf path on success.
# Requires: cp1_user, cp1_host (set by upgrade_cluster)
_worker_pre_hook() {
    local user="$1" host="$2" sudo_pfx="$3"
    local remote_admin_conf
    remote_admin_conf=$(_deploy_ssh "$user" "$host" "${sudo_pfx}mktemp /tmp/upgrade-admin-XXXXXX")
    remote_admin_conf=$(echo "$remote_admin_conf" | tr -d '[:space:]')
    local tmp_admin_conf
    tmp_admin_conf=$(mktemp /tmp/admin-conf-XXXXXX)
    chmod 600 "$tmp_admin_conf"
    if ! _deploy_ssh "$cp1_user" "$cp1_host" "${sudo_pfx}cat /etc/kubernetes/admin.conf" > "$tmp_admin_conf" 2>/dev/null; then
        log_error "  [${host}] Failed to download admin.conf from control-plane ${cp1_host}"
        rm -f "$tmp_admin_conf"
        _deploy_ssh "$user" "$host" "${sudo_pfx}rm -f '$remote_admin_conf'" >/dev/null 2>&1 || true
        return 1
    fi
    if [ ! -s "$tmp_admin_conf" ]; then
        log_error "  [${host}] Downloaded admin.conf is empty"
        rm -f "$tmp_admin_conf"
        _deploy_ssh "$user" "$host" "${sudo_pfx}rm -f '$remote_admin_conf'" >/dev/null 2>&1 || true
        return 1
    fi
    _deploy_scp "$tmp_admin_conf" "$user" "$host" "$remote_admin_conf" >/dev/null 2>&1
    _deploy_ssh "$user" "$host" "${sudo_pfx}chmod 600 '$remote_admin_conf'" >/dev/null 2>&1
    rm -f "$tmp_admin_conf"
    echo "$remote_admin_conf"
}

# Worker post-hook: clean up remote admin.conf.
_worker_post_hook() {
    local user="$1" host="$2" sudo_pfx="$3" remote_admin_conf="$4"
    [ -n "$remote_admin_conf" ] && _deploy_ssh "$user" "$host" "${sudo_pfx}rm -f '$remote_admin_conf'" >/dev/null 2>&1 || true
}

# Main upgrade orchestration (remote mode)
upgrade_cluster() {
    local cp_count w_count
    cp_count=$(_csv_count "$DEPLOY_CONTROL_PLANES")
    w_count=0
    [ -n "$DEPLOY_WORKERS" ] && w_count=$(_csv_count "$DEPLOY_WORKERS")

    # State/resume support (only when --resume is enabled)
    if [ "${RESUME_ENABLED:-false}" = true ]; then
        local resume_file
        resume_file=$(_state_find_resume "upgrade")
        if [ -n "$resume_file" ]; then
            _state_load "$resume_file"
            log_info "Resuming previous upgrade operation..."
        else
            log_info "No resumable upgrade state found, starting fresh."
            _state_init "upgrade"
        fi
    fi
    _state_set "target_version" "$UPGRADE_TARGET_VERSION"

    _audit_log "upgrade" "started" "target=${UPGRADE_TARGET_VERSION} cp=${cp_count} workers=${w_count}"
    log_info "Upgrading Kubernetes cluster to v${UPGRADE_TARGET_VERSION}: ${cp_count} control-plane(s), ${w_count} worker(s)"

    # Build combined node list and initialize remote session
    local all_nodes="$DEPLOY_CONTROL_PLANES"
    [ -n "$DEPLOY_WORKERS" ] && all_nodes="${all_nodes},${DEPLOY_WORKERS}"

    local _step=0

    # --- Step 1: SSH connectivity check ---
    _step=$((_step + 1))
    log_info "Step ${_step}: Checking SSH connectivity to all nodes..."
    # --- Step 2: Transfer setup-k8s.sh to all nodes ---
    _step=$((_step + 1))
    if ! remote_session_open "upgrade" "$all_nodes"; then
        return 1
    fi
    if [ -n "${KUBEADM_PATCHES_DIR:-}" ] && ! remote_send_dir "$KUBEADM_PATCHES_DIR" kubeadm-patches; then
        log_error "Failed to transfer kubeadm patches"
        remote_session_close
        return 1
    fi

    # --- Step 3: Get current version from first CP ---
    _step=$((_step + 1))
    log_info "Step ${_step}: Checking current cluster version..."
    local cp0
    cp0=$(_csv_get "$DEPLOY_CONTROL_PLANES" 0)
    _parse_node_address "$cp0"
    # cp1_user/cp1_host used by _upgrade_single_node, _worker_pre_hook (closure-like)
    cp1_user="$_NODE_USER"; cp1_host="$_NODE_HOST"
    local sudo_pfx; sudo_pfx=$(_sudo_prefix "$cp1_user")

    local current_version
    current_version=$(_deploy_ssh "$cp1_user" "$cp1_host" "${sudo_pfx}kubeadm version -o short" | sed 's/^v//' | tr -d '[:space:]')
    if [ -z "$current_version" ]; then
        log_error "Failed to get current Kubernetes version from ${cp1_host}"
        return 1
    fi
    log_info "Current cluster version: v${current_version}"
    log_info "Target version: v${UPGRADE_TARGET_VERSION}"

    # Auto-step-upgrade: compute intermediate versions if minor gap > 1
    if [ "${UPGRADE_AUTO_STEP:-false}" = true ]; then
        local cur_minor tar_minor
        cur_minor=$(echo "$current_version" | cut -d. -f2)
        tar_minor=$(echo "$UPGRADE_TARGET_VERSION" | cut -d. -f2)
        if [ "$tar_minor" -gt $((cur_minor + 1)) ]; then
            local steps final_target="$UPGRADE_TARGET_VERSION"
            steps=$(_compute_upgrade_steps "$current_version" "$UPGRADE_TARGET_VERSION")
            local step_count=0
            for _sv in $steps; do step_count=$((step_count + 1)); done
            log_info "Auto-step-upgrade: ${step_count} step(s) to reach v${final_target}"
            # Each step opens its own session
            remote_session_close
            # Step through each intermediate version using recursive calls
            UPGRADE_AUTO_STEP=false  # prevent recursion
            for step_version in $steps; do
                log_info ""
                log_info "========================================="
                log_info "Auto-step: upgrading to v${step_version}"
                log_info "========================================="
                UPGRADE_TARGET_VERSION="$step_version"
                if ! upgrade_cluster; then
                    log_error "Auto-step upgrade failed at v${step_version}"
                    UPGRADE_TARGET_VERSION="$final_target"
                    UPGRADE_AUTO_STEP=true
                    return 1
                fi
                log_info "Auto-step: v${step_version} complete"
            done
            UPGRADE_TARGET_VERSION="$final_target"
            UPGRADE_AUTO_STEP=true
            log_info ""
            log_info "Auto-step upgrade to v${UPGRADE_TARGET_VERSION} completed successfully!"
            return 0
        fi
    fi

    # Validate version constraints (single minor version step)
    _validate_upgrade_version "$current_version" "$UPGRADE_TARGET_VERSION"

    # --- Pre-upgrade health check ---
    log_info ""
    _health_check_cluster "$cp1_user" "$cp1_host" --pre || true
    log_info ""

    # --- Step 5: Run kubeadm upgrade plan (informational) ---
    _step=$((_step + 1))
    log_info "Step ${_step}: Running kubeadm upgrade plan..."
    local plan_output
    plan_output=$(_deploy_ssh "$cp1_user" "$cp1_host" "${sudo_pfx}kubeadm upgrade plan" 2>&1) || true
    log_info "$plan_output"

    # --- Step 6: Upgrade control-plane nodes (sequential) ---
    _step=$((_step + 1))
    log_info "Step ${_step}: Upgrading control-plane nodes..."
    local upgrade_failed=false

    _i=0
    while [ "$_i" -lt "$cp_count" ]; do
        node=$(_csv_get "$DEPLOY_CONTROL_PLANES" "$_i")
        is_first=$([ "$_i" -eq 0 ] && echo true || echo false)
        if ! _upgrade_single_node "$node" "upgrade_cp" "$is_first"; then
            upgrade_failed=true; break
        fi
        if [ "$is_first" = true ] && ! _upgrade_verify_api_version "$cp1_user" "$cp1_host" "$UPGRADE_TARGET_VERSION"; then
            upgrade_failed=true; break
        fi
        _i=$((_i + 1))
    done

    if [ "$upgrade_failed" = true ]; then
        log_error "Control-plane upgrade failed. Check logs above for details."
        log_error "Some nodes may be in mixed-version state (this is allowed by K8s skew policy)."
        remote_session_close
        return 1
    fi

    # --- Step 7: Upgrade worker nodes (sequential) ---
    if [ "$w_count" -gt 0 ]; then
        _step=$((_step + 1))
        log_info "Step ${_step}: Upgrading worker nodes..."

        _i=0
        while [ "$_i" -lt "$w_count" ]; do
            node=$(_csv_get "$DEPLOY_WORKERS" "$_i")
            if ! _upgrade_single_node "$node" "upgrade_worker" false _worker_pre_hook _worker_post_hook; then
                upgrade_failed=true; break
            fi
            _i=$((_i + 1))
        done
    fi

    # --- Step 8: Verify ---
    _step=$((_step + 1))
    log_info "Step ${_step}: Verifying cluster state..."
    local verify_output
    verify_output=$(_deploy_ssh "$cp1_user" "$cp1_host" "${sudo_pfx}kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes -o wide" 2>&1) || true
    log_info "$verify_output"

    # --- Post-upgrade health check ---
    log_info ""
    _health_check_cluster "$cp1_user" "$cp1_host" --post || true

    # --- Step 9: Clean up remote bundle directories ---
    _step=$((_step + 1))
    log_info "Step ${_step}: Cleaning up remote working directories..."
    remote_session_close

    # --- Step 10: Summary ---
    log_info ""
    log_info "=== Upgrade Summary ==="
    log_info ""
    log_info "Target Version: v${UPGRADE_TARGET_VERSION}"
    log_info ""
    _log_node_list "Control-Plane Nodes" "$DEPLOY_CONTROL_PLANES"
    if [ "$w_count" -gt 0 ]; then
        log_info ""
        _log_node_list "Worker Nodes" "$DEPLOY_WORKERS"
    fi
    log_info ""
    log_info "=========================="

    if [ "$upgrade_failed" = true ]; then
        _state_set "status" "failed"
        _audit_log "upgrade" "failed" "target=${UPGRADE_TARGET_VERSION}"
        log_error "Some worker upgrades failed. Check logs above."
        return 1
    fi

    _state_complete
    _audit_log "upgrade" "completed" "target=${UPGRADE_TARGET_VERSION}"
    log_info "Cluster upgrade completed successfully!"
    return 0
}
