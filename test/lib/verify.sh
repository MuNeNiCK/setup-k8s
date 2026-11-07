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
# <run_fn> runs a command on the VM as root (e.g. vm_ssh, which escalates
# with sudo/doas, or a wrapper around vm_ssh_root). Each check is piped to
# "sh -s" through it, so that a whole command line runs as root.

VERIFY_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

_verify_fail=0
_VERIFY_RUN=""
# Run a shell command line on the VM as root
_vr() { printf '%s\n' "$1" | $_VERIFY_RUN "sh -s" 2>/dev/null; }
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
    _VERIFY_RUN="$1"
    local distro="$2" requested="$3"
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
    server=$(_vr "kubectl $kc version -o json 2>/dev/null" | awk -F'"' '/"serverVersion"/ {s = 1} s && /"gitVersion"/ {print $4; exit}')
    kubeadm_v=$(_vr "kubeadm version -o short" 2>/dev/null | tr -d '[:space:]')
    kubelet_v=$(_vr "kubelet --version" 2>/dev/null | awk '{print $2}')
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
    runtime=$(_vr "crictl version 2>/dev/null" | awk '/RuntimeName/ {print $2}')
    if [ "${opt[--cri]:-containerd}" = crio ]; then
        _vcheck "container runtime" "cri-o" "$runtime"
    else
        _vcheck "container runtime" "containerd" "$runtime"
    fi

    # --- kube-proxy mode ---
    local mode want_mode="${opt[--proxy-mode]:-auto}"
    mode=$(_vr "kubectl $kc -n kube-system get configmap kube-proxy -o jsonpath='{.data.config\\.conf}'" 2>/dev/null | awk '/^mode:/ {gsub(/"/, "", $2); print $2}')
    [ -n "$mode" ] || mode=iptables
    if [ "$want_mode" = auto ]; then
        local kernel minor
        kernel=$(_vr "uname -r" | tr -d '[:space:]')
        minor=$(echo "$server" | cut -d. -f2)
        want_mode=iptables
        # Same rule as setup-k8s: Kubernetes 1.33+, kernel 5.13+, nf_tables available
        if [ "${minor:-0}" -ge 33 ] && awk -v k="$kernel" 'BEGIN { split(k, v, /[.-]/); exit !(v[1] > 5 || (v[1] == 5 && v[2] >= 13)) }' \
            && _vr "modprobe -n nf_tables || test -d /sys/module/nf_tables"; then
            want_mode=nftables
        fi
    fi
    _vcheck "kube-proxy mode" "$want_mode" "$mode"

    # --- networking and API server ---
    local cluster_config
    cluster_config=$(_vr "kubectl $kc -n kube-system get configmap kubeadm-config -o jsonpath='{.data.ClusterConfiguration}'" 2>/dev/null)
    _yaml_value() { printf '%s\n' "$cluster_config" | sed -n "s/^ *$1: *//p" | head -n 1 | tr -d "'\""; }
    [ -n "${opt[--pod-network-cidr]:-}" ] && _vcheck "pod network CIDR" "${opt[--pod-network-cidr]}" "$(_yaml_value podSubnet)"
    [ -n "${opt[--service-cidr]:-}" ] && _vcheck "service CIDR" "${opt[--service-cidr]}" "$(_yaml_value serviceSubnet)"
    [ -n "${opt[--control-plane-endpoint]:-}" ] && _vcheck "control plane endpoint" "${opt[--control-plane-endpoint]}" "$(_yaml_value controlPlaneEndpoint)"
    if [ -n "${opt[--apiserver-advertise-address]:-}" ]; then
        _vcheck "API server advertise address" "${opt[--apiserver-advertise-address]}" \
            "$(_vr "sed -n 's/^ *- --advertise-address=//p' /etc/kubernetes/manifests/kube-apiserver.yaml")"
    fi
    if [ -n "${opt[--api-server-extra-sans]:-}" ]; then
        local san check
        for san in ${opt[--api-server-extra-sans]//,/ }; do
            case "$san" in *[!0-9a-fA-F.:]*) check="-checkhost" ;; *) check="-checkip" ;; esac
            _vcheck_true "API server certificate has SAN ${san}" _vr \
                "openssl x509 -noout -in /etc/kubernetes/pki/apiserver.crt ${check} '${san}' | grep -q 'does match'"
        done
    fi
    if [ -n "${opt[--kubelet-node-ip]:-}" ]; then
        _vcheck "kubelet node IP" "${opt[--kubelet-node-ip]}" \
            "$(_vr "kubectl $kc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type==\"InternalIP\")].address}'" 2>/dev/null)"
    fi

    # --- kubelet configuration ---
    local kubelet_config
    kubelet_config=$(_vr "cat /var/lib/kubelet/config.yaml" 2>/dev/null)
    if [[ "$flags" == *" --swap-enabled "* ]]; then
        _vcheck_true "kubelet allows swap (failSwapOn: false)" grep -q '^failSwapOn: false' <<<"$kubelet_config"
        _vcheck_true "kubelet uses LimitedSwap" grep -q 'swapBehavior: LimitedSwap' <<<"$kubelet_config"
    fi
    if [ -n "${opt[--kubeadm-config-patch]:-}" ]; then
        local patch_line
        patch_line=$(_vr "grep -v -E '^(apiVersion|kind):' '${opt[--kubeadm-config-patch]}'" 2>/dev/null | head -n 1)
        _vcheck_true "kubeadm config patch applied (${patch_line})" grep -qxF "$patch_line" <<<"$kubelet_config"
    fi

    # --- tools ---
    if [ "${opt[--install-helm]:-false}" = true ]; then
        _vcheck "Helm version" "v$(_verify_default HELM_VERSION)" "$(_vr "/usr/local/bin/helm version --template '{{.Version}}'" 2>/dev/null)"
    fi
    if [ "${opt[--install-kustomize]:-false}" = true ]; then
        _vcheck "Kustomize version" "v$(_verify_default KUSTOMIZE_VERSION)" "$(_vr "/usr/local/bin/kustomize version" 2>/dev/null | tr -d '[:space:]')"
    fi
    local bash_dir_exists=false
    _vr "test -d /etc/bash_completion.d" && bash_dir_exists=true
    if [ "${opt[--enable-completion]:-true}" = false ]; then
        _vcheck_true "no kubectl completion installed" _vr "test ! -e /etc/bash_completion.d/kubectl"
    else
        local shells="${opt[--completion-shells]:-auto}" sh_name user="${LOGIN_USER:-root}"
        if [ "$shells" = auto ]; then
            # setup-k8s follows the shell of the user who ran it (sudo)
            shells=$(_vr "getent passwd '${user}' | cut -d: -f7" | xargs -r basename)
        fi
        for sh_name in ${shells//,/ }; do
            case "$sh_name" in
                bash)
                    if [ "$bash_dir_exists" = true ]; then
                        _vcheck_true "kubectl bash completion installed" _vr "test -s /etc/bash_completion.d/kubectl"
                    else
                        log_info "CHECK: bash completion skipped (no /etc/bash_completion.d on this distribution)"
                    fi ;;
                zsh)
                    if _vr "test -d /usr/share/zsh/site-functions -o -d /usr/local/share/zsh/site-functions"; then
                        _vcheck_true "kubectl zsh completion installed" _vr "test -s /usr/share/zsh/site-functions/_kubectl -o -s /usr/local/share/zsh/site-functions/_kubectl"
                    else
                        log_info "CHECK: zsh completion skipped (zsh is not installed)"
                    fi ;;
                fish)
                    if [ "$user" != root ]; then
                        _vcheck_true "kubectl fish completion installed for ${user}" _vr \
                            "test -s \"\$(getent passwd '${user}' | cut -d: -f6)/.config/fish/completions/kubectl.fish\""
                    fi ;;
            esac
        done
    fi

    # --- logging ---
    if [ -n "${opt[--log-dir]:-}" ]; then
        _vcheck_true "log file written to ${opt[--log-dir]}" _vr "ls '${opt[--log-dir]}'/setup-k8s-*.log >/dev/null 2>&1 && test -s \"\$(ls -t '${opt[--log-dir]}'/setup-k8s-*.log | head -n 1)\""
    fi
    if [[ "$flags" == *" --audit-syslog "* ]]; then
        _vcheck_true "audit entries sent to syslog" _vr \
            "journalctl -t setup-k8s --no-pager 2>/dev/null | grep -q 'AUDIT:' || grep -q 'setup-k8s.*AUDIT:' /var/log/syslog /var/log/messages 2>/dev/null"
    fi

    return "$_verify_fail"
}

verify_no_leftovers() {
    local left
    left=$($1 "sh -s" < "$VERIFY_ROOT_DIR/test/lib/leftovers.sh" 2>/dev/null)
    if [ -z "$left" ]; then
        log_success "CHECK: nothing left behind after cleanup"
        return 0
    fi
    log_error "CHECK: left behind after cleanup: $(echo "$left" | tr '\n' ' ')"
    return 1
}
