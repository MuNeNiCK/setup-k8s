#!/bin/sh

# Disable swap
disable_swap() {
    log_info "Disabling swap..."
    swapoff -a
    # Backup fstab before modifying swap entries (for cleanup restoration)
    if grep -q '^[^#].*[[:space:]]swap[[:space:]]' /etc/fstab; then
        cp /etc/fstab /etc/fstab.pre-k8s
    fi
    # Match swap entries with any whitespace (spaces or tabs) and skip already-commented lines
    sed -i '/^[^#].*[[:space:]]swap[[:space:]]/ s/^/#/' /etc/fstab
}

# Restore swap entries in /etc/fstab during cleanup
restore_fstab_swap() {
    log_info "Restoring swap entries in /etc/fstab..."
    local swap_restored=false
    if [ -f /etc/fstab.pre-k8s ]; then
        # Merge only swap-related lines from backup into current fstab.
        # This avoids overwriting legitimate admin changes made after setup.
        local swap_lines
        swap_lines=$(grep '[[:space:]]swap[[:space:]]' /etc/fstab.pre-k8s | grep -v '^#' || true)
        if [ -n "$swap_lines" ]; then
            # Remove our commented-out swap lines and insert originals (deduplicated)
            sed -i '/^#.*[[:space:]]swap[[:space:]]/d' /etc/fstab
            echo "$swap_lines" | while IFS= read -r line; do
                if ! grep -qF "$line" /etc/fstab; then
                    echo "$line" >> /etc/fstab
                fi
            done
            log_info "Swap entries restored from backup (merged into current /etc/fstab)"
            swap_restored=true
        fi
        rm -f /etc/fstab.pre-k8s
    else
        # No backup found: cannot safely determine which swap lines were commented
        # by this tool vs. pre-existing user comments. Log a warning instead of
        # blindly uncommenting all swap lines.
        if grep -q '^#.*[[:space:]]swap[[:space:]]' /etc/fstab; then
            log_warn "No fstab backup found (/etc/fstab.pre-k8s). Cannot safely restore swap entries."
            log_warn "If swap was disabled by this tool, manually uncomment swap lines in /etc/fstab."
        fi
    fi
    # Re-enable swap only if we actually restored fstab entries
    if [ "$swap_restored" = true ]; then
        if ! swapon -a 2>/dev/null; then
            log_warn "swapon -a failed; some swap devices may not be re-enabled"
        fi
    fi
}

# Disable zram swap (especially for Fedora and Arch)
disable_zram_swap() {
    log_info "Checking and disabling zram swap if present..."
    if grep -q zram /proc/swaps || [ "$DISTRO_NAME" = "fedora" ] || [ "$DISTRO_NAME" = "arch" ] || [ "$DISTRO_NAME" = "manjaro" ]; then
        log_info "zram swap detected or Fedora/Arch system, disabling..."
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