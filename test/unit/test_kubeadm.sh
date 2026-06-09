#!/bin/sh
# Unit tests for lib/kubeadm.sh

# ============================================================
# Test: generate_kubeadm_config with extra SANs
# ============================================================
test_generate_kubeadm_config_extra_sans() {
    echo "=== Test: generate_kubeadm_config with extra SANs ==="
    (
        . "$PROJECT_ROOT/lib/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        _kubeadm_api_version() { echo "kubeadm.k8s.io/v1beta4"; }
        _kubeproxy_api_version() { echo "kubeproxy.config.k8s.io/v1alpha1"; }
        _kubelet_api_version() { echo "kubelet.config.k8s.io/v1beta1"; }
        get_cri_socket() { echo "unix:///run/containerd/containerd.sock"; }
        . "$PROJECT_ROOT/lib/bootstrap.sh"
        . "$PROJECT_ROOT/lib/helpers.sh"
        . "$PROJECT_ROOT/lib/kubeadm.sh"
        . "$PROJECT_ROOT/commands/init.sh"

        KUBEADM_POD_CIDR=""
        KUBEADM_SERVICE_CIDR=""
        KUBEADM_API_ADDR=""
        KUBEADM_CP_ENDPOINT=""
        API_SERVER_EXTRA_SANS="lb.example.com,10.0.0.100"
        KUBEADM_CONFIG_PATCH=""

        local config_file
        config_file=$(generate_kubeadm_config)
        local content
        content=$(cat "$config_file")
        rm -f "$config_file"

        local has_san1="false"
        echo "$content" | grep -q "lb.example.com" && has_san1="true"
        _assert_eq "extra SAN lb.example.com in config" "true" "$has_san1"

        local has_san2="false"
        echo "$content" | grep -q "10.0.0.100" && has_san2="true"
        _assert_eq "extra SAN 10.0.0.100 in config" "true" "$has_san2"

        local has_certsans="false"
        echo "$content" | grep -q "certSANs:" && has_certsans="true"
        _assert_eq "certSANs section in config" "true" "$has_certsans"
    )
}

# ============================================================
# Test: generate_kubeadm_config quotes IPv6 literals
# ============================================================
test_generate_kubeadm_config_ipv6_literals() {
    echo "=== Test: generate_kubeadm_config quotes IPv6 literals ==="
    (
        . "$PROJECT_ROOT/lib/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        _kubeadm_api_version() { echo "kubeadm.k8s.io/v1beta4"; }
        _kubeproxy_api_version() { echo "kubeproxy.config.k8s.io/v1alpha1"; }
        _kubelet_api_version() { echo "kubelet.config.k8s.io/v1beta1"; }
        get_cri_socket() { echo "unix:///run/containerd/containerd.sock"; }
        . "$PROJECT_ROOT/lib/bootstrap.sh"
        . "$PROJECT_ROOT/lib/helpers.sh"
        . "$PROJECT_ROOT/lib/kubeadm.sh"
        . "$PROJECT_ROOT/commands/init.sh"

        KUBEADM_POD_CIDR="fd00:10:244::/48"
        KUBEADM_SERVICE_CIDR="fd00:20::/108"
        KUBEADM_API_ADDR="fd00:10:2::15"
        KUBEADM_CP_ENDPOINT="[fd00:10:2::15]:6443"
        API_SERVER_EXTRA_SANS="setup-k8s.local,fd00:10:2::15"
        KUBEADM_CONFIG_PATCH=""

        local config_file
        config_file=$(generate_kubeadm_config)
        local content
        content=$(cat "$config_file")
        rm -f "$config_file"

        echo "$content" | grep -q "advertiseAddress: 'fd00:10:2::15'"
        _assert_eq "IPv6 advertiseAddress quoted" "0" "$?"

        echo "$content" | grep -q "controlPlaneEndpoint: '\\[fd00:10:2::15\\]:6443'"
        _assert_eq "IPv6 controlPlaneEndpoint quoted" "0" "$?"

        echo "$content" | grep -q "  - 'fd00:10:2::15'"
        _assert_eq "IPv6 SAN quoted" "0" "$?"
    )
}

# ============================================================
# Test: generate_kubeadm_config with config patch
# ============================================================
test_generate_kubeadm_config_patch() {
    echo "=== Test: generate_kubeadm_config with config patch ==="
    (
        . "$PROJECT_ROOT/lib/variables.sh"
        log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
        _kubeadm_api_version() { echo "kubeadm.k8s.io/v1beta4"; }
        _kubeproxy_api_version() { echo "kubeproxy.config.k8s.io/v1alpha1"; }
        _kubelet_api_version() { echo "kubelet.config.k8s.io/v1beta1"; }
        get_cri_socket() { echo "unix:///run/containerd/containerd.sock"; }
        . "$PROJECT_ROOT/lib/helpers.sh"
        . "$PROJECT_ROOT/lib/kubeadm.sh"
        . "$PROJECT_ROOT/commands/init.sh"

        # shellcheck disable=SC2034 # used by generate_kubeadm_config
        KUBEADM_POD_CIDR=""
        # shellcheck disable=SC2034 # used by generate_kubeadm_config
        KUBEADM_SERVICE_CIDR=""
        # shellcheck disable=SC2034 # used by generate_kubeadm_config
        KUBEADM_API_ADDR=""
        # shellcheck disable=SC2034 # used by generate_kubeadm_config
        KUBEADM_CP_ENDPOINT=""
        # shellcheck disable=SC2034 # used by generate_kubeadm_config
        API_SERVER_EXTRA_SANS=""

        local tmpfile
        tmpfile=$(mktemp /tmp/test-patch-XXXXXX)
        echo "customKey: customValue" > "$tmpfile"
        # shellcheck disable=SC2034 # used by generate_kubeadm_config
        KUBEADM_CONFIG_PATCH="$tmpfile"

        local config_file
        config_file=$(generate_kubeadm_config)
        local content
        content=$(cat "$config_file")
        rm -f "$config_file" "$tmpfile"

        local has_patch="false"
        echo "$content" | grep -q "customKey: customValue" && has_patch="true"
        _assert_eq "config patch appended" "true" "$has_patch"
    )
}
