#!/bin/sh

# CRI (Container Runtime Interface) helpers.
# Containerd TOML generation, CRI socket, crictl config, CRI-O management.
#
# Depends on: lib/core/system.sh (_detect_init_system, _service_*), lib/core/k8s_version.sh (k8s_pause_image)

# Helper: configure containerd TOML with v2 layout, SystemdCgroup=true, sandbox_image
configure_containerd_toml() {
    log_info "Generating and tuning containerd config..."
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml

    # Set SystemdCgroup based on init system
    if [ "$(_detect_init_system)" = "systemd" ]; then
        sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    else
        sed -i 's/SystemdCgroup = true/SystemdCgroup = false/g' /etc/containerd/config.toml
    fi

    # Only inject a version header when the generated config lacks one
    if ! grep -q '^version *= *[0-9]' /etc/containerd/config.toml 2>/dev/null; then
        sed -i '1s/^/version = 2\n/' /etc/containerd/config.toml
    fi

    # Set sandbox_image to the pause image of the installed kubeadm
    local _pause_image
    _pause_image=$(k8s_pause_image)
    if grep -q '^\s*sandbox_image\s*=\s*"' /etc/containerd/config.toml; then
        sed -i "s#^\s*sandbox_image\s*=\s*\".*\"#  sandbox_image = \"${_pause_image}\"#" /etc/containerd/config.toml
    else
        # Insert under the CRI plugin section
        if awk -v pause_img="${_pause_image}" '
            BEGIN{inserted=0}
            {print}
            $0 ~ /^\[plugins\."io\.containerd\.grpc\.v1\.cri"\]/ && inserted==0 {print "  sandbox_image = \"" pause_img "\""; inserted=1}
        ' /etc/containerd/config.toml > /etc/containerd/config.toml.tmp; then
            mv /etc/containerd/config.toml.tmp /etc/containerd/config.toml
        else
            log_error "Failed to inject sandbox_image into containerd config"
            rm -f /etc/containerd/config.toml.tmp
            return 1
        fi
    fi

    _service_reload
    _service_enable containerd
    _service_restart containerd
    if ! _service_is_active containerd; then
        log_error "containerd failed to start after configuration"
        case "$(_detect_init_system)" in
            systemd) systemctl status containerd --no-pager 2>/dev/null || true ;;
            openrc)  rc-service containerd status 2>/dev/null || true ;;
        esac
        return 1
    fi
}

# Install the SELinux policy for containers on RPM-based systems with
# SELinux. The SELinux mode itself is not changed.
cri_install_selinux_policy() {
    [ "$(pkg_format)" = rpm ] || return 0
    [ -d /usr/share/selinux ] || command -v getenforce >/dev/null 2>&1 || return 0
    if ! pkg_installed container-selinux; then
        log_info "Installing container-selinux..."
        pkg_install container-selinux || log_warn "container-selinux could not be installed"
    fi
}

# Helper: Get CRI socket path based on runtime
get_cri_socket() {
    case "$CRI" in
        containerd)
            echo "unix:///run/containerd/containerd.sock"
            ;;
        crio)
            echo "unix:///var/run/crio/crio.sock"
            ;;
    esac
}

# Helper: configure crictl runtime endpoint
configure_crictl() {
    local endpoint
    endpoint=$(get_cri_socket)
    log_info "Configuring crictl at /etc/crictl.yaml (endpoint: $endpoint)"
    cat > /etc/crictl.yaml <<EOF
runtime-endpoint: $endpoint
image-endpoint: $endpoint
timeout: 10
debug: false
pull-image-on-create: false
EOF
}

# Finalize containerd setup: configure TOML and crictl
_finalize_containerd_setup() {
    # Before the restart in configure_containerd_toml
    proxy_configure_runtime containerd
    configure_containerd_toml
    configure_crictl
}

# Start CRI-O with error diagnostics
_start_crio_with_diagnostics() {
    _service_reload
    _service_enable crio
    # Restart (not start) so that a running CRI-O loads the new configuration
    if ! _service_restart crio || ! _service_is_active crio; then
        log_error "Failed to start CRI-O service"
        case "$(_detect_init_system)" in
            systemd)
                systemctl status crio --no-pager 2>/dev/null || true
                journalctl -u crio -n 100 --no-pager 2>/dev/null || true
                ;;
            openrc) rc-service crio status 2>/dev/null || true ;;
        esac
        return 1
    fi
}

# Write a CRI-O drop-in config with cgroup_manager and pause_image.
# Usage: _write_crio_config <conf_name> <cgroup_manager>
# CRI-O drop-in directory (overridable for tests)
_CRIO_CONF_DIR="/etc/crio/crio.conf.d"

_write_crio_config() {
    local conf_name="$1" cgroup_mgr="$2"
    mkdir -p "$_CRIO_CONF_DIR"
    cat > "${_CRIO_CONF_DIR}/${conf_name}" <<EOF
[crio.runtime]
cgroup_manager = "${cgroup_mgr}"

[crio.image]
pause_image = "$(k8s_pause_image)"
EOF
    _write_crio_cgroupv1_runtime
}

# crun (the default OCI runtime) cannot set device permissions on cgroups v1
# ("write to devices.allow: Operation not permitted"); use runc there. A
# drop-in that sorts after the packages' own (10-crio.conf sets crun).
_CRIO_CGROUPV1_CONF="99-setup-k8s-cgroupv1.conf"
_write_crio_cgroupv1_runtime() {
    local runc=""
    rm -f "${_CRIO_CONF_DIR}/${_CRIO_CGROUPV1_CONF}"
    _has_cgroupv2 && return 0
    for runc in /usr/libexec/crio/runc "$(command -v runc 2>/dev/null)"; do
        [ -n "$runc" ] && [ -x "$runc" ] && break
        runc=""
    done
    if [ -z "$runc" ]; then
        log_warn "cgroups v1 and no runc: CRI-O's default runtime may fail to create containers"
        return 0
    fi
    cat > "${_CRIO_CONF_DIR}/${_CRIO_CGROUPV1_CONF}" <<EOF
[crio.runtime]
default_runtime = "runc"

[crio.runtime.runtimes.runc]
runtime_path = "${runc}"
EOF
}

# Finalize CRI-O setup: start service with diagnostics and configure crictl.
_finalize_crio_setup() {
    proxy_configure_runtime crio
    _start_crio_with_diagnostics || return 1
    configure_crictl
}
