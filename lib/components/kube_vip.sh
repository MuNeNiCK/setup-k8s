#!/bin/sh

# kubectl / kube-vip helpers (shared by init, join, deploy).

# Helper: Configure kubectl for a user after kubeadm init/join
_configure_kubectl() {
    log_info "Configuring kubectl..."
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        local USER_HOME
        USER_HOME=$(get_user_home "$SUDO_USER")
        mkdir -p "$USER_HOME/.kube"
        cp -f /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
        chown -R "$SUDO_USER:$(id -gn "$SUDO_USER")" "$USER_HOME/.kube"
        log_info "Created kubectl configuration for user $SUDO_USER"
    else
        mkdir -p /root/.kube
        cp -f /etc/kubernetes/admin.conf /root/.kube/config
        log_info "Created kubectl configuration for root user at /root/.kube/config"
    fi
}

# Determine kubeconfig path for kube-vip.
# K8s 1.29+ generates super-admin.conf (server: localhost:6443) which avoids
# the chicken-and-egg problem where admin.conf points to the VIP that kube-vip
# hasn't yet claimed.  For K8s < 1.29 super-admin.conf doesn't exist, so fall
# back to admin.conf (which still points to localhost on those versions).
_kube_vip_kubeconfig_path() {
    local k8s_minor
    k8s_minor=$(echo "$K8S_VERSION" | cut -d. -f2)
    if [ -n "$k8s_minor" ] && [ "$k8s_minor" -ge 29 ] 2>/dev/null; then
        echo "/etc/kubernetes/super-admin.conf"
    else
        echo "/etc/kubernetes/admin.conf"
    fi
}

# Generate kube-vip static pod manifest (unified for all CRIs)
_generate_kube_vip_manifest() {
    local vip="$1" iface="$2" image="$3" kubeconfig_path="$4"
    cat <<KVEOF
apiVersion: v1
kind: Pod
metadata:
  name: kube-vip
  namespace: kube-system
spec:
  containers:
  - name: kube-vip
    image: ${image}
    args:
    - manager
    env:
    - name: vip_arp
      value: "true"
    - name: port
      value: "6443"
    - name: vip_interface
      value: "${iface}"
    - name: vip_cidr
      value: "$(_is_ipv6 "$vip" && echo "128" || echo "32")"
    - name: cp_enable
      value: "true"
    - name: cp_namespace
      value: kube-system
    - name: vip_ddns
      value: "false"
    - name: vip_leaderelection
      value: "true"
    - name: vip_leasename
      value: plndr-cp-lock
    - name: vip_leaseduration
      value: "5"
    - name: vip_renewdeadline
      value: "3"
    - name: vip_retryperiod
      value: "1"
    - name: address
      value: "${vip}"
    securityContext:
      capabilities:
        add:
        - NET_ADMIN
        - NET_RAW
    volumeMounts:
    - mountPath: /etc/kubernetes/admin.conf
      name: kubeconfig
  hostAliases:
  - hostnames:
    - kubernetes
    ip: 127.0.0.1
  hostNetwork: true
  volumes:
  - hostPath:
      path: ${kubeconfig_path}
    name: kubeconfig
KVEOF
}

# Remove pre-added VIP on failure
_rollback_vip() {
    local vip="$HA_VIP_ADDRESS"
    local iface="$HA_VIP_INTERFACE"
    local inet_keyword="inet"
    local vip_prefix="32"
    if _is_ipv6 "$vip"; then
        inet_keyword="inet6"
        vip_prefix="128"
    fi
    if ip addr show dev "$iface" 2>/dev/null | grep -q "${inet_keyword} ${vip}/"; then
        log_info "Rolling back pre-added VIP $vip from $iface..."
        local _vip_err
        if ! _vip_err=$(ip addr del "${vip}/${vip_prefix}" dev "$iface" 2>&1); then
            log_warn "VIP rollback failed: $_vip_err"
        fi
    fi
}

# Verify kube-vip kubeconfig file exists after kubeadm init/join.
# If the expected file doesn't exist, patch the manifest to use admin.conf.
_verify_kube_vip_kubeconfig() {
    local expected_path
    expected_path=$(_kube_vip_kubeconfig_path)
    if [ ! -f "$expected_path" ]; then
        log_warn "Expected kubeconfig $expected_path not found"
        if [ "$expected_path" != "/etc/kubernetes/admin.conf" ] && [ -f "/etc/kubernetes/admin.conf" ]; then
            log_info "Patching kube-vip manifest to use /etc/kubernetes/admin.conf instead..."
            if ! sed -i "s|path: ${expected_path}|path: /etc/kubernetes/admin.conf|" \
                /etc/kubernetes/manifests/kube-vip.yaml; then
                log_warn "Failed to patch kube-vip manifest; kube-vip may use incorrect kubeconfig path"
            fi
        fi
    fi
}

deploy_kube_vip() {
    local skip_vip_preadd=false
    if [ "${1:-}" = "--skip-vip-preadd" ]; then
        skip_vip_preadd=true
        shift
    fi

    local vip="$HA_VIP_ADDRESS"
    local iface="$HA_VIP_INTERFACE"
    local kube_vip_image="ghcr.io/kube-vip/kube-vip:${KUBE_VIP_VERSION}"
    local manifest_dir="/etc/kubernetes/manifests"
    local kubeconfig_path
    kubeconfig_path=$(_kube_vip_kubeconfig_path)

    log_info "Deploying kube-vip for HA (VIP=$vip, interface=$iface)..."
    log_info "  kubeconfig: $kubeconfig_path"
    mkdir -p "$manifest_dir"

    # Pull image based on CRI
    if [ "$CRI" = "crio" ]; then
        log_info "Pulling kube-vip image via crictl..."
        crictl pull "$kube_vip_image"
    else
        log_info "Pulling kube-vip image via ctr..."
        ctr image pull "$kube_vip_image"
    fi

    # Generate manifest from unified template (same for all CRIs)
    _generate_kube_vip_manifest "$vip" "$iface" "$kube_vip_image" "$kubeconfig_path" \
        > "${manifest_dir}/kube-vip.yaml"

    log_info "kube-vip manifest written to ${manifest_dir}/kube-vip.yaml"

    # Pre-add VIP to the interface so it is reachable during kubeadm init
    # before kube-vip can perform leader election.
    # On join nodes, skip pre-add to avoid VIP conflicts with the existing leader.
    local inet_keyword="inet"
    local vip_prefix="32"
    if _is_ipv6 "$vip"; then
        inet_keyword="inet6"
        vip_prefix="128"
    fi
    if [ "$skip_vip_preadd" = false ]; then
        if ! ip addr show dev "$iface" | grep -q "${inet_keyword} ${vip}/"; then
            log_info "Pre-adding VIP $vip to $iface for bootstrap..."
            ip addr add "${vip}/${vip_prefix}" dev "$iface"
        fi
    else
        log_info "Skipping VIP pre-add (join mode, VIP managed by existing leader)"
    fi
}
