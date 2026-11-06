#!/bin/sh

# CRI (Container Runtime Interface) helpers.
# Containerd TOML generation, CRI socket, crictl config, CRI-O management.
#
# Depends on: lib/core/system.sh (_detect_init_system, _service_*), lib/core/defaults.sh (PAUSE_IMAGE_VERSION)

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

    # Set sandbox_image to registry.k8s.io/pause:<version>
    local _pause_image="registry.k8s.io/pause:${PAUSE_IMAGE_VERSION}"
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
    configure_containerd_toml
    configure_crictl
}

# Start CRI-O with error diagnostics
_start_crio_with_diagnostics() {
    _service_reload
    _service_enable crio
    _service_start crio || {
        log_error "Failed to start CRI-O service"
        case "$(_detect_init_system)" in
            systemd)
                systemctl status crio --no-pager 2>/dev/null || true
                journalctl -u crio -n 100 --no-pager 2>/dev/null || true
                ;;
        esac
        return 1
    }
}

# Write a CRI-O drop-in config with cgroup_manager and pause_image.
# Usage: _write_crio_config <conf_name> <cgroup_manager>
_write_crio_config() {
    local conf_name="$1" cgroup_mgr="$2"
    mkdir -p /etc/crio/crio.conf.d
    cat > "/etc/crio/crio.conf.d/${conf_name}" <<EOF
[crio.runtime]
cgroup_manager = "${cgroup_mgr}"

[crio.image]
pause_image = "registry.k8s.io/pause:${PAUSE_IMAGE_VERSION}"
EOF
}

# Finalize CRI-O setup: start service with diagnostics and configure crictl.
_finalize_crio_setup() {
    _start_crio_with_diagnostics
    configure_crictl
}
