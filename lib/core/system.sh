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

# === kubeadm Preflight Ignore (OpenRC) ===

_kubeadm_preflight_ignore_args() {
    if [ "$(_detect_init_system)" != "systemd" ]; then
        echo "--ignore-preflight-errors=SystemVerification"
    fi
}
