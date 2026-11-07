#!/bin/sh

# Swap must stay off across reboots, otherwise kubelet (failSwapOn) exits at
# boot. Swap is activated at boot from /etc/fstab and from systemd .swap
# units that are not in fstab (units installed by packages or the
# administrator, cloud images, GPT auto-discovery). swapoff alone only lasts
# until the next boot, so fstab entries are commented out and every systemd
# swap unit gets a drop-in that prevents it from starting. (systemctl mask
# does not work for units whose file is in /etc/systemd/system, the usual
# place for administrator-created swap units.) Changes are recorded so that
# cleanup restores exactly what was changed.

# Files changed by disable_swap (overridable for tests)
_FSTAB_FILE="/etc/fstab"
_SYSTEMD_UNIT_DIR="/etc/systemd/system"
_SWAP_UNITS_MARKER="/var/lib/setup-k8s-swap-units-disabled"
_SWAP_DROPIN_NAME="90-setup-k8s-swap-off.conf"

# Print the names of systemd swap units (one per line), excluding zram units
# (handled by disable_zram_swap): units that are loaded or enabled.
_systemd_swap_units() {
    {
        systemctl list-units --type=swap --all --plain --no-legend 2>/dev/null | awk '{print $1}'
        systemctl list-unit-files --type=swap --plain --no-legend 2>/dev/null | awk '$2 == "enabled" {print $1}'
    } | grep -v '^dev-zram' | grep '\.swap$' | sort -u
}

# Prevent every systemd swap unit from starting at boot.
_block_systemd_swap_units() {
    [ "$(_detect_init_system)" = "systemd" ] || return 0
    local unit dir
    _systemd_swap_units | while IFS= read -r unit; do
        [ -n "$unit" ] || continue
        dir="${_SYSTEMD_UNIT_DIR}/${unit}.d"
        [ -f "${dir}/${_SWAP_DROPIN_NAME}" ] && continue
        log_info "Disabling swap unit $unit at boot (drop-in ${dir}/${_SWAP_DROPIN_NAME})..."
        mkdir -p "$dir"
        cat > "${dir}/${_SWAP_DROPIN_NAME}" <<'DROPIN'
# Written by setup-k8s: kubelet requires swap to be off.
# Removed by "setup-k8s.sh cleanup".
[Unit]
ConditionPathExists=/nonexistent/setup-k8s-keeps-swap-off
DROPIN
        mkdir -p "$(dirname "$_SWAP_UNITS_MARKER")"
        echo "$unit" >> "$_SWAP_UNITS_MARKER"
        systemctl stop "$unit" >/dev/null 2>&1 || true
    done
}

# Disable swap now and for future boots
disable_swap() {
    log_info "Disabling swap..."
    # Backup fstab before modifying swap entries (for cleanup restoration)
    if grep -q '^[^#].*[[:space:]]swap[[:space:]]' "$_FSTAB_FILE"; then
        cp "$_FSTAB_FILE" "${_FSTAB_FILE}.pre-k8s"
    fi
    # Match swap entries with any whitespace (spaces or tabs) and skip already-commented lines
    sed -i '/^[^#].*[[:space:]]swap[[:space:]]/ s/^/#/' "$_FSTAB_FILE"
    _block_systemd_swap_units
    swapoff -a
    if [ "$(_detect_init_system)" = "systemd" ]; then
        # Regenerate units from the edited fstab
        systemctl daemon-reload 2>/dev/null || true
    fi
}

# Remove the drop-ins written by disable_swap.
# Prints "true" when at least one unit was restored.
_unblock_systemd_swap_units() {
    local unit restored=false
    if [ -f "$_SWAP_UNITS_MARKER" ]; then
        while IFS= read -r unit; do
            [ -n "$unit" ] || continue
            log_info "Re-enabling swap unit $unit (disabled by setup-k8s)..."
            rm -f "${_SYSTEMD_UNIT_DIR}/${unit}.d/${_SWAP_DROPIN_NAME}"
            rmdir "${_SYSTEMD_UNIT_DIR}/${unit}.d" 2>/dev/null || true
            restored=true
        done < "$_SWAP_UNITS_MARKER"
        rm -f "$_SWAP_UNITS_MARKER"
    fi
    echo "$restored"
}

# Restore swap disabled by disable_swap (fstab entries and systemd units)
restore_fstab_swap() {
    log_info "Restoring swap entries in /etc/fstab..."
    local swap_restored=false
    if [ "$(_detect_init_system)" = "systemd" ] && [ "$(_unblock_systemd_swap_units)" = true ]; then
        swap_restored=true
    fi
    if [ -f "${_FSTAB_FILE}.pre-k8s" ]; then
        # Merge only swap-related lines from backup into current fstab.
        # This avoids overwriting legitimate admin changes made after setup.
        local swap_lines
        swap_lines=$(grep '[[:space:]]swap[[:space:]]' "${_FSTAB_FILE}.pre-k8s" | grep -v '^#' || true)
        if [ -n "$swap_lines" ]; then
            # Remove our commented-out swap lines and insert originals (deduplicated)
            sed -i '/^#.*[[:space:]]swap[[:space:]]/d' "$_FSTAB_FILE"
            echo "$swap_lines" | while IFS= read -r line; do
                if ! grep -qF "$line" "$_FSTAB_FILE"; then
                    echo "$line" >> "$_FSTAB_FILE"
                fi
            done
            log_info "Swap entries restored from backup (merged into current /etc/fstab)"
            swap_restored=true
        fi
        rm -f "${_FSTAB_FILE}.pre-k8s"
    else
        # No backup found: cannot safely determine which swap lines were commented
        # by this tool vs. pre-existing user comments. Log a warning instead of
        # blindly uncommenting all swap lines.
        if grep -q '^#.*[[:space:]]swap[[:space:]]' "$_FSTAB_FILE"; then
            log_warn "No fstab backup found (${_FSTAB_FILE}.pre-k8s). Cannot safely restore swap entries."
            log_warn "If swap was disabled by this tool, manually uncomment swap lines in /etc/fstab."
        fi
    fi
    # Re-enable swap only if we actually restored something
    if [ "$swap_restored" = true ]; then
        if [ "$(_detect_init_system)" = "systemd" ]; then
            systemctl daemon-reload 2>/dev/null || true
            systemctl start swap.target 2>/dev/null || true
        fi
        if ! swapon -a 2>/dev/null; then
            log_warn "swapon -a failed; some swap devices may not be re-enabled"
        fi
    fi
}

# Succeed when zram swap is active or configured to start at boot
# (zram-generator, used by Fedora and Arch among others).
_zram_swap_present() {
    grep -q zram /proc/swaps 2>/dev/null && return 0
    [ -f /etc/systemd/zram-generator.conf ] && return 0
    [ -f /usr/lib/systemd/zram-generator.conf ] && return 0
    [ -n "$(ls /etc/systemd/zram-generator.conf.d/ 2>/dev/null)" ] && return 0
    return 1
}

# Disable zram swap
disable_zram_swap() {
    log_info "Checking and disabling zram swap if present..."
    if _zram_swap_present; then
        log_info "zram swap detected, disabling..."
        local k8s_zram_marker="/var/lib/setup-k8s-zram-masked"
        : > "$k8s_zram_marker"
        # Stop, disable, and mask all potential zram swap services (systemd-only)
        if [ "$(_detect_init_system)" = "systemd" ]; then
            for service in zram-swap.service systemd-zram-setup@zram0.service dev-zram0.swap; do
                if [ "$(systemctl is-active "$service" 2>/dev/null)" = "active" ]; then
                    log_info "Stopping and disabling $service..."
                    systemctl stop "$service"
                    systemctl disable "$service"
                fi
                if [ "$(systemctl is-enabled "$service" 2>/dev/null)" != "masked" ]; then
                    log_info "Masking $service to prevent automatic activation..."
                    if systemctl mask "$service" 2>/dev/null; then
                        echo "$service" >> "$k8s_zram_marker"
                    fi
                fi
            done

            # Handle zram-generator configuration
            if [ -f /usr/lib/systemd/zram-generator.conf ] || [ -d /etc/systemd/zram-generator.conf.d ]; then
                log_info "Disabling zram swap configuration..."
                mkdir -p /etc/systemd/zram-generator.conf.d
                cat > /etc/systemd/zram-generator.conf.d/k8s-disable-zram.conf <<EOF
[zram0]
zram-fraction=0
max-zram-size=0
EOF
            fi
        fi

        # Unload zram kernel module if loaded
        if lsmod | grep -q zram; then
            log_info "Unloading zram kernel module..."
            modprobe -r zram || true
        fi

        # Disable all swap
        swapoff -a

        if [ -n "$(swapon --show 2>/dev/null)" ]; then
            log_warn "Some swap devices could not be disabled:"
            swapon --show
            log_warn "You may need to disable swap manually or set --fail-swap-on=false in kubelet configuration."
        else
            log_info "All swap has been successfully disabled."
        fi
    fi
}

# Restore zram swap during cleanup
restore_zram_swap() {
    log_info "Checking and restoring zram swap if it was disabled..."
    local k8s_zram_marker="/var/lib/setup-k8s-zram-masked"
    # Only restore if we have evidence that this tool disabled zram
    if [ -f "$k8s_zram_marker" ] || [ -f /etc/systemd/zram-generator.conf.d/k8s-disable-zram.conf ]; then
        log_info "Restoring zram swap services..."

        # Unmask services that were masked by this tool
        if [ -f "$k8s_zram_marker" ] && [ "$(_detect_init_system)" = "systemd" ]; then
            while IFS= read -r service; do
                [ -z "$service" ] && continue
                log_info "Unmasking $service (masked by setup-k8s)..."
                systemctl unmask "$service" 2>/dev/null || true
            done < "$k8s_zram_marker"
        fi
        rm -f "$k8s_zram_marker"

        # Remove the k8s-specific disable configuration we created
        rm -f /etc/systemd/zram-generator.conf.d/k8s-disable-zram.conf

        if [ "$(_detect_init_system)" = "systemd" ]; then
            # Reload systemd to pick up changes
            systemctl daemon-reload

            # Re-enable and start zram services
            for service in zram-swap.service systemd-zram-setup@zram0.service; do
                if systemctl list-unit-files | grep -q "^$service"; then
                    log_info "Enabling and starting $service..."
                    systemctl enable "$service" 2>/dev/null || true
                    systemctl start "$service" 2>/dev/null || true
                fi
            done
        fi

        # Load zram module if it's not loaded
        if ! lsmod | grep -q zram; then
            log_info "Loading zram kernel module..."
            modprobe zram 2>/dev/null || true
        fi

        # Trigger systemd-managed swap units
        if [ "$(_detect_init_system)" = "systemd" ]; then
            systemctl start swap.target 2>/dev/null || true
        fi

        log_info "zram swap restoration completed."
    fi
}