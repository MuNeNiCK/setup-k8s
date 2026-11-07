#!/bin/bash
# Checks of the result of setup-k8s on a VM, shared by the scenarios.
#
#   verify_setup <run_fn> <distro> <requested_version> <setup_args...>
#       Check that a node set up with "init <setup_args>" has what those
#       arguments ask for: Kubernetes version (control plane, kubeadm,
#       kubelet), container runtime, kube-proxy mode, networking, API server
#       address and SANs, kubelet node IP, swap, kubeadm config patch, Helm,
#       Kustomize, shell completion, file and syslog logging. Prints a CHECK
#       line per item and returns 1 when any check fails.
#   verify_no_leftovers <run_fn>
#       Check that cleanup removed packages, binaries, package locks,
#       repositories, keys, services, and configuration. Returns 1 otherwise.
#
# <run_fn> runs one shell command on the VM as root and prints its output
# (e.g. vm_ssh with escalation, or a wrapper around vm_ssh_root).

VERIFY_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

_verify_fail=0
_vcheck() {
    local desc="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then
        log_success "CHECK: ${desc} = ${got}"
    else
        log_error "CHECK: ${desc} = '${got}' (expected '${want}')"
        _verify_fail=1
    fi
}
_vcheck_true() {
    local desc="$1"; shift
    if "$@"; then
        log_success "CHECK: ${desc}"
    else
        log_error "CHECK: ${desc}"
        _verify_fail=1
    fi
}

# Value of NAME="${NAME:-value}" in lib/core/defaults.sh (leading "v" removed)
_verify_default() {
    sed -n "s/^$1=\"\${$1:-v\{0,1\}\([^}]*\)}\".*/\1/p" "$VERIFY_ROOT_DIR/lib/core/defaults.sh"
}

verify_setup() {
    local run="$1" distro="$2" requested="$3"
    shift 3
    _verify_fail=0
    local kc="--kubeconfig=/etc/kubernetes/admin.conf"

    # --- options given ---
    local -A opt=()
    local flags=" "
    while [ $# -gt 0 ]; do
        case "$1" in
            --*)
                if [ $# -ge 2 ] && [[ "$2" != --* ]]; then
                    opt["$1"]="$2"; shift 2
                else
                    flags="${flags}$1 "; shift
                fi
                ;;
            *) shift ;;
        esac
    done
    [ -n "$requested" ] && opt[--kubernetes-version]="$requested"

    # --- Kubernetes version ---
    local server kubeadm_v kubelet_v want
    server=$($run "kubectl $kc version -o json 2>/dev/null" | awk -F'"' '/"serverVersion"/ {s = 1} s && /"gitVersion"/ {print $4; exit}')
    kubeadm_v=$($run "kubeadm version -o short" 2>/dev/null | tr -d '[:space:]')
    kubelet_v=$($run "kubelet --version" 2>/dev/null | awk '{print $2}')
    _vcheck "kubeadm version matches the control plane" "$server" "$kubeadm_v"
    _vcheck "kubelet version matches the control plane" "$server" "$kubelet_v"
    want="${opt[--kubernetes-version]:-}"
    if [ -z "$want" ]; then
        case "$distro" in
            alpine-*|archlinux-*) ;;  # the distribution's version
            *)
                local marker=stable
                [[ "$flags" == *" --prerelease "* ]] && marker=latest
                want=$(curl -fsSL --retry 3 "https://dl.k8s.io/release/${marker}.txt" | sed 's/^v//')
                ;;
        esac
    fi
    case "$want" in
        "") ;;
        *.*.*) _vcheck "control plane version" "v${want}" "$server" ;;
        *)     _vcheck "control plane minor version" "v${want}" "$(echo "$server" | cut -d. -f1,2)" ;;
    esac

    # --- container runtime ---
    local runtime
    runtime=$($run "crictl version 2>/dev/null" | awk '/RuntimeName/ {print $2}')
    if [ "${opt[--cri]:-containerd}" = crio ]; then
        _vcheck "container runtime" "cri-o" "$runtime"
    else
        _vcheck "container runtime" "containerd" "$runtime"
    fi

    # --- kube-proxy mode ---
    local mode want_mode="${opt[--proxy-mode]:-auto}"
    mode=$($run "kubectl $kc -n kube-system get configmap kube-proxy -o jsonpath='{.data.config\\.conf}'" 2>/dev/null | awk '/^mode:/ {gsub(/"/, "", $2); print $2}')
    [ -n "$mode" ] || mode=iptables
    if [ "$want_mode" = auto ]; then
        local kernel minor
        kernel=$($run "uname -r" | tr -d '[:space:]')
        minor=$(echo "$server" | cut -d. -f2)
        want_mode=iptables
        if [ "${minor:-0}" -ge 33 ] && printf '%s\n%s\n' "5.13" "$kernel" | sort -V | head -n 1 | grep -qx '5.13'; then
            want_mode=nftables
        fi
    fi
    _vcheck "kube-proxy mode" "$want_mode" "$mode"

    # --- networking and API server ---
    local cluster_config
    cluster_config=$($run "kubectl $kc -n kube-system get configmap kubeadm-config -o jsonpath='{.data.ClusterConfiguration}'" 2>/dev/null)
    _yaml_value() { printf '%s\n' "$cluster_config" | sed -n "s/^ *$1: *//p" | head -n 1 | tr -d "'\""; }
    [ -n "${opt[--pod-network-cidr]:-}" ] && _vcheck "pod network CIDR" "${opt[--pod-network-cidr]}" "$(_yaml_value podSubnet)"
    [ -n "${opt[--service-cidr]:-}" ] && _vcheck "service CIDR" "${opt[--service-cidr]}" "$(_yaml_value serviceSubnet)"
    [ -n "${opt[--control-plane-endpoint]:-}" ] && _vcheck "control plane endpoint" "${opt[--control-plane-endpoint]}" "$(_yaml_value controlPlaneEndpoint)"
    if [ -n "${opt[--apiserver-advertise-address]:-}" ]; then
        _vcheck "API server advertise address" "${opt[--apiserver-advertise-address]}" \
            "$($run "sed -n 's/^ *- --advertise-address=//p' /etc/kubernetes/manifests/kube-apiserver.yaml")"
    fi
    if [ -n "${opt[--api-server-extra-sans]:-}" ]; then
        local sans san
        sans=$($run "openssl x509 -noout -ext subjectAltName -in /etc/kubernetes/pki/apiserver.crt" 2>/dev/null)
        for san in ${opt[--api-server-extra-sans]//,/ }; do
            _vcheck_true "API server certificate has SAN ${san}" grep -q -E "(DNS|IP Address):${san}(,|$)" <<<"$sans"
        done
    fi
    if [ -n "${opt[--kubelet-node-ip]:-}" ]; then
        _vcheck "kubelet node IP" "${opt[--kubelet-node-ip]}" \
            "$($run "kubectl $kc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type==\"InternalIP\")].address}'" 2>/dev/null)"
    fi

    # --- kubelet configuration ---
    local kubelet_config
    kubelet_config=$($run "cat /var/lib/kubelet/config.yaml" 2>/dev/null)
    if [[ "$flags" == *" --swap-enabled "* ]]; then
        _vcheck_true "kubelet allows swap (failSwapOn: false)" grep -q '^failSwapOn: false' <<<"$kubelet_config"
        _vcheck_true "kubelet uses LimitedSwap" grep -q 'swapBehavior: LimitedSwap' <<<"$kubelet_config"
    fi
    if [ -n "${opt[--kubeadm-config-patch]:-}" ]; then
        local patch_line
        patch_line=$($run "grep -v -E '^(apiVersion|kind):' '${opt[--kubeadm-config-patch]}'" 2>/dev/null | head -n 1)
        _vcheck_true "kubeadm config patch applied (${patch_line})" grep -qxF "$patch_line" <<<"$kubelet_config"
    fi

    # --- tools ---
    if [ "${opt[--install-helm]:-false}" = true ]; then
        _vcheck "Helm version" "v$(_verify_default HELM_VERSION)" "$($run "/usr/local/bin/helm version --template '{{.Version}}'" 2>/dev/null)"
    fi
    if [ "${opt[--install-kustomize]:-false}" = true ]; then
        _vcheck "Kustomize version" "v$(_verify_default KUSTOMIZE_VERSION)" "$($run "/usr/local/bin/kustomize version" 2>/dev/null | tr -d '[:space:]')"
    fi
    if [ "${opt[--enable-completion]:-true}" = false ]; then
        _vcheck_true "no kubectl completion installed" $run "test ! -e /etc/bash_completion.d/kubectl"
    else
        local shells="${opt[--completion-shells]:-auto}" sh_name
        for sh_name in ${shells//,/ }; do
            case "$sh_name" in
                bash|auto) _vcheck_true "kubectl bash completion installed" $run "test -s /etc/bash_completion.d/kubectl" ;;
                zsh) _vcheck_true "kubectl zsh completion installed" $run \
                        "test ! -d /usr/share/zsh/site-functions -a ! -d /usr/local/share/zsh/site-functions || test -s /usr/share/zsh/site-functions/_kubectl || test -s /usr/local/share/zsh/site-functions/_kubectl" ;;
                fish) _vcheck_true "kubectl fish completion installed" $run \
                        "h=\$(getent passwd \"\${SUDO_USER:-root}\" | cut -d: -f6); test \"\${SUDO_USER:-root}\" = root || test -s \"\$h/.config/fish/completions/kubectl.fish\"" ;;
            esac
        done
    fi

    # --- logging ---
    if [ -n "${opt[--log-dir]:-}" ]; then
        _vcheck_true "log file written to ${opt[--log-dir]}" $run "ls '${opt[--log-dir]}'/setup-k8s-*.log >/dev/null 2>&1 && test -s \"\$(ls -t '${opt[--log-dir]}'/setup-k8s-*.log | head -n 1)\""
    fi
    if [[ "$flags" == *" --audit-syslog "* ]]; then
        _vcheck_true "audit entries sent to syslog" $run \
            "journalctl -t setup-k8s --no-pager 2>/dev/null | grep -q 'AUDIT:' || grep -q 'setup-k8s.*AUDIT:' /var/log/syslog /var/log/messages 2>/dev/null"
    fi

    return "$_verify_fail"
}

verify_no_leftovers() {
    local run="$1" left
    left=$($run "sh -s" < "$VERIFY_ROOT_DIR/test/lib/leftovers.sh" 2>/dev/null)
    if [ -z "$left" ]; then
        log_success "CHECK: nothing left behind after cleanup"
        return 0
    fi
    log_error "CHECK: left behind after cleanup: $(echo "$left" | tr '\n' ' ')"
    return 1
}
