#!/bin/sh

# Low-level system detection and service abstraction (init system, architecture).

# === Architecture and Init System Detection ===

_detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l|armv6l) echo "arm" ;;
        s390x)   echo "s390x" ;;
        ppc64le) echo "ppc64le" ;;
        *)       log_warn "Unknown architecture: $arch"; echo "$arch" ;;
    esac
}

# Kernel release to inspect (overridable for tests)
_kernel_release() { uname -r; }

# Succeed when the running kernel is at least MAJOR.MINOR.
# Usage: _kernel_version_ge <major.minor>
_kernel_version_ge() {
    local rel major minor want_major want_minor
    rel=$(_kernel_release)
    major=$(echo "$rel" | cut -d. -f1)
    minor=$(echo "$rel" | cut -d. -f2 | sed 's/[^0-9].*//')
    want_major="${1%%.*}"
    want_minor="${1#*.}"
    case "$major$minor" in *[!0-9]*|"") return 1 ;; esac
    [ "$major" -gt "$want_major" ] && return 0
    [ "$major" -eq "$want_major" ] && [ "${minor:-0}" -ge "$want_minor" ]
}

_detect_init_system() {
    if command -v systemctl >/dev/null 2>&1 && systemctl --version >/dev/null 2>&1; then
        echo "systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        echo "openrc"
    else
        echo "unknown"
    fi
}

# === Service Abstraction (systemd / OpenRC) ===

_service_enable() {
    local svc="$1"
    case "$(_detect_init_system)" in
        systemd) systemctl enable "$svc" ;;
        openrc)  rc-update add "$svc" default ;;
    esac
}

_service_start() {
    local svc="$1"
    case "$(_detect_init_system)" in
        systemd) systemctl start "$svc" ;;
        openrc)  rc-service "$svc" start ;;
    esac
}

_service_stop() {
    local svc="$1"
    case "$(_detect_init_system)" in
        systemd) systemctl stop "$svc" 2>/dev/null || true ;;
        openrc)  rc-service "$svc" stop 2>/dev/null || true ;;
    esac
}

_service_restart() {
    local svc="$1"
    case "$(_detect_init_system)" in
        systemd) systemctl restart "$svc" ;;
        openrc)  rc-service "$svc" restart ;;
    esac
}

_service_disable() {
    local svc="$1"
    case "$(_detect_init_system)" in
        systemd) systemctl disable "$svc" 2>/dev/null || true ;;
        openrc)  rc-update del "$svc" default 2>/dev/null || true ;;
    esac
}

_service_is_active() {
    local svc="$1"
    case "$(_detect_init_system)" in
        systemd) systemctl is-active --quiet "$svc" ;;
        openrc)  rc-service "$svc" status >/dev/null 2>&1 ;;
    esac
}

_service_reload() {
    case "$(_detect_init_system)" in
        systemd) systemctl daemon-reload ;;
        openrc)  : ;; # OpenRC does not need daemon-reload
    esac
}

# === Host preparation (based on observed state, not distribution names) ===

_K8S_SHARED_MOUNT_SCRIPT="/etc/local.d/k8s-shared-mount.start"

# Prepare host settings that kubelet expects and that systemd would otherwise
# provide: a machine ID, shared mount propagation, and mounted cgroups.
system_prepare() {
    if [ ! -s /etc/machine-id ]; then
        log_info "Generating /etc/machine-id..."
        if command -v dbus-uuidgen >/dev/null 2>&1; then
            dbus-uuidgen > /etc/machine-id
        else
            tr -d '-' < /proc/sys/kernel/random/uuid > /etc/machine-id
        fi
    fi

    if [ "$(_detect_init_system)" = "openrc" ]; then
        if [ -x /etc/init.d/cgroups ]; then
            rc-update add cgroups boot 2>/dev/null || true
            rc-service cgroups start 2>/dev/null || true
        fi
        mount --make-rshared / 2>/dev/null || true
        if [ ! -f "$_K8S_SHARED_MOUNT_SCRIPT" ]; then
            log_info "Persisting shared mount propagation..."
            mkdir -p "$(dirname "$_K8S_SHARED_MOUNT_SCRIPT")"
            printf '#!/bin/sh\nmount --make-rshared /\n' > "$_K8S_SHARED_MOUNT_SCRIPT"
            chmod +x "$_K8S_SHARED_MOUNT_SCRIPT"
            rc-update add local default 2>/dev/null || true
        fi
    fi

    if [ ! -e /sys/fs/cgroup/cpu ] && [ ! -e /sys/fs/cgroup/cgroup.controllers ]; then
        log_info "Cgroups not mounted — setting up cgroup filesystem..."
        mount -t tmpfs cgroup_root /sys/fs/cgroup 2>/dev/null || true
        local subsys
        for subsys in cpu cpuacct memory devices freezer blkio pids; do
            mkdir -p "/sys/fs/cgroup/${subsys}"
            mount -t cgroup -o "${subsys}" "cgroup_${subsys}" "/sys/fs/cgroup/${subsys}" 2>/dev/null || true
        done
    fi
}

# Remove host preparation artifacts created by system_prepare.
system_cleanup() {
    if [ -f "$_K8S_SHARED_MOUNT_SCRIPT" ]; then
        log_info "Removing shared mount startup script..."
        rm -f "$_K8S_SHARED_MOUNT_SCRIPT"
    fi
}

# === kubeadm Preflight Ignore (OpenRC) ===

_kubeadm_preflight_ignore_args() {
    if [ "$(_detect_init_system)" != "systemd" ]; then
        echo "--ignore-preflight-errors=SystemVerification"
    fi
}
