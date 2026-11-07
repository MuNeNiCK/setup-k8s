#!/bin/sh

# HTTP proxy for nodes that reach the internet through a proxy.
#
# --http-proxy URL, --https-proxy URL, --no-proxy LIST. Without the options,
# local commands use the http_proxy/HTTP_PROXY, https_proxy/HTTPS_PROXY, and
# no_proxy/NO_PROXY environment variables (sudo drops them unless run with
# -E). Remote commands pass only the options to the nodes.
#
# The settings are exported for setup-k8s itself (curl, the package managers,
# kubeadm, ctr) and written to the service environment of the container
# runtime, which pulls the images. NO_PROXY always contains what Kubernetes
# reaches inside the cluster: loopback, the node and API server addresses, the
# Pod and Service networks, and the cluster DNS domains.
#
#   _is_proxy_flag <arg>                       Succeed for a proxy option
#   _parse_proxy_flag <argc> <flag> <value>    Parse one (caller shifts $_PROXY_SHIFT)
#   proxy_forward_args <passthrough>           Print <passthrough> plus the proxy options
#   proxy_enabled                              Succeed when a proxy is configured
#   proxy_apply_env                            Export the settings for this process
#   proxy_configure_runtime <service>          Write the runtime's proxy environment
#   proxy_verify_runtime <service>             Check that the running runtime has it
#   proxy_cleanup                              Remove what proxy_configure_runtime wrote

HTTP_PROXY_URL=""
HTTPS_PROXY_URL=""
NO_PROXY_LIST=""
_PROXY_NO_PROXY=""
_PROXY_SHIFT=0

# Paths (overridable for tests)
_PROXY_SYSTEMD_DIR="/etc/systemd/system"
_PROXY_OPENRC_CONF_DIR="/etc/conf.d"
_PROXY_DROPIN="10-setup-k8s-proxy.conf"
_PROXY_BEGIN="# BEGIN setup-k8s proxy"
_PROXY_END="# END setup-k8s proxy"
_PROXY_RUNTIMES="containerd crio"

_is_proxy_flag() {
    case "$1" in --http-proxy|--https-proxy|--no-proxy) return 0 ;; esac
    return 1
}

_parse_proxy_flag() {
    _require_value "$1" "$2" "${3:-}"
    case "$2" in
        --http-proxy|--https-proxy)
            case "$3" in
                http://*|https://*) ;;
                *)
                    log_error "$2 must be an http:// or https:// URL (got: $3)"
                    exit 1
                    ;;
            esac
            if [ "$2" = --http-proxy ]; then HTTP_PROXY_URL="$3"; else HTTPS_PROXY_URL="$3"; fi
            ;;
        --no-proxy) NO_PROXY_LIST="$3" ;;
    esac
    _PROXY_SHIFT=2
}

# Usage: VAR=$(proxy_forward_args "$VAR")
proxy_forward_args() {
    local out="$1"
    [ -n "$HTTP_PROXY_URL" ] && out=$(_passthrough_add_pair "$out" --http-proxy "$HTTP_PROXY_URL")
    [ -n "$HTTPS_PROXY_URL" ] && out=$(_passthrough_add_pair "$out" --https-proxy "$HTTPS_PROXY_URL")
    [ -n "$NO_PROXY_LIST" ] && out=$(_passthrough_add_pair "$out" --no-proxy "$NO_PROXY_LIST")
    printf '%s' "$out"
}

# Options win; otherwise the environment of this process
_proxy_load_env() {
    [ -n "${HTTP_PROXY_URL}${HTTPS_PROXY_URL}${NO_PROXY_LIST}" ] && return 0
    HTTP_PROXY_URL="${http_proxy:-${HTTP_PROXY:-}}"
    HTTPS_PROXY_URL="${https_proxy:-${HTTPS_PROXY:-}}"
    NO_PROXY_LIST="${no_proxy:-${NO_PROXY:-}}"
}

proxy_enabled() {
    [ -n "${HTTP_PROXY_URL}${HTTPS_PROXY_URL}" ]
}

# Host part of host:port, [v6]:port, or a bare address
_proxy_host() {
    local h="$1"
    case "$h" in
        \[*\]*) h="${h#\[}"; h="${h%%\]*}" ;;
        *:*:*) ;;             # bare IPv6 address
        *:*) h="${h%:*}" ;;
    esac
    printf '%s' "$h"
}

# NO_PROXY: the given list plus the destinations inside the cluster
_proxy_no_proxy() {
    local items="${NO_PROXY_LIST}" addr
    items="${items},localhost,127.0.0.1,::1,.svc,.svc.cluster.local,.cluster.local"
    items="${items},${KUBEADM_SERVICE_CIDR:-10.96.0.0/12}"
    [ -n "${KUBEADM_POD_CIDR:-}" ] && items="${items},${KUBEADM_POD_CIDR}"
    for addr in "${KUBEADM_API_ADDR:-}" "${KUBELET_NODE_IP:-}" "${HA_VIP_ADDRESS:-}" \
                "$(_proxy_host "${KUBEADM_CP_ENDPOINT:-}")" "$(_proxy_host "${JOIN_ADDRESS:-}")"; do
        [ -n "$addr" ] && items="${items},${addr}"
    done
    for addr in $(ip -o addr show scope global 2>/dev/null | awk '{ sub(/\/.*/, "", $4); print $4 }'); do
        items="${items},${addr}"
    done
    printf '%s\n' "$items" | tr ',' '\n' | sed 's/^ *//; s/ *$//' \
        | awk 'NF && !seen[$0]++ { out = out (out == "" ? "" : ",") $0 } END { print out }'
}

proxy_apply_env() {
    _proxy_load_env
    proxy_enabled || return 0
    _PROXY_NO_PROXY=$(_proxy_no_proxy)
    if [ -n "$HTTP_PROXY_URL" ]; then
        export http_proxy="$HTTP_PROXY_URL" HTTP_PROXY="$HTTP_PROXY_URL"
    fi
    if [ -n "$HTTPS_PROXY_URL" ]; then
        export https_proxy="$HTTPS_PROXY_URL" HTTPS_PROXY="$HTTPS_PROXY_URL"
    fi
    export no_proxy="$_PROXY_NO_PROXY" NO_PROXY="$_PROXY_NO_PROXY"
    log_info "Using the HTTP proxy ${HTTPS_PROXY_URL:-$HTTP_PROXY_URL} (no proxy for: ${_PROXY_NO_PROXY})"
}

# "NAME=value" lines of the proxy environment
_proxy_env_lines() {
    if [ -n "$HTTP_PROXY_URL" ]; then
        echo "HTTP_PROXY=${HTTP_PROXY_URL}"
        echo "http_proxy=${HTTP_PROXY_URL}"
    fi
    if [ -n "$HTTPS_PROXY_URL" ]; then
        echo "HTTPS_PROXY=${HTTPS_PROXY_URL}"
        echo "https_proxy=${HTTPS_PROXY_URL}"
    fi
    echo "NO_PROXY=${_PROXY_NO_PROXY}"
    echo "no_proxy=${_PROXY_NO_PROXY}"
}

# Usage: proxy_configure_runtime <containerd|crio>
proxy_configure_runtime() {
    local svc="$1" conf line
    proxy_enabled || return 0
    [ -n "$_PROXY_NO_PROXY" ] || _PROXY_NO_PROXY=$(_proxy_no_proxy)
    case "$(_detect_init_system)" in
        systemd)
            mkdir -p "${_PROXY_SYSTEMD_DIR}/${svc}.service.d"
            {
                echo "# Written by setup-k8s: proxy for image pulls"
                echo "[Service]"
                # "%" starts a specifier in unit files
                _proxy_env_lines | sed 's/%/%%/g; s/.*/Environment="&"/'
            } > "${_PROXY_SYSTEMD_DIR}/${svc}.service.d/${_PROXY_DROPIN}"
            _service_reload
            ;;
        openrc)
            conf="${_PROXY_OPENRC_CONF_DIR}/${svc}"
            mkdir -p "$_PROXY_OPENRC_CONF_DIR"
            _proxy_remove_block "$conf"
            {
                echo "$_PROXY_BEGIN"
                _proxy_env_lines | while IFS= read -r line; do
                    printf "export %s='%s'\n" "${line%%=*}" "${line#*=}"
                done
                echo "$_PROXY_END"
            } >> "$conf"
            ;;
        *)
            log_warn "Unknown init system: set the proxy for ${svc} manually"
            ;;
    esac
}

# Remove the managed block from an OpenRC conf.d file
_proxy_remove_block() {
    [ -f "$1" ] || return 0
    awk -v b="$_PROXY_BEGIN" -v e="$_PROXY_END" '$0 == b { skip = 1; next } $0 == e { skip = 0; next } !skip' "$1" > "$1.tmp" \
        && mv "$1.tmp" "$1"
}

# The running runtime must have the proxy environment (restarted after the
# configuration was written). Usage: proxy_verify_runtime <containerd|crio>
proxy_verify_runtime() {
    local svc="$1" pid env line
    proxy_enabled || return 0
    pid=$(pidof "$svc" 2>/dev/null | awk '{print $1}')
    if [ -z "$pid" ] || [ ! -r "/proc/${pid}/environ" ]; then
        log_error "Cannot check the proxy environment of ${svc} (not running)"
        return 1
    fi
    env=$(tr '\0' '\n' < "/proc/${pid}/environ")
    for line in $(_proxy_env_lines | grep -E '^(HTTPS?_PROXY)='); do
        if ! printf '%s\n' "$env" | grep -qxF "$line"; then
            log_error "${svc} runs without ${line%%=*} (image pulls would not use the proxy)"
            return 1
        fi
    done
    log_info "${svc} uses the HTTP proxy for image pulls"
}

proxy_cleanup() {
    local svc
    for svc in $_PROXY_RUNTIMES; do
        rm -f "${_PROXY_SYSTEMD_DIR}/${svc}.service.d/${_PROXY_DROPIN}"
        rmdir "${_PROXY_SYSTEMD_DIR}/${svc}.service.d" 2>/dev/null || true
        _proxy_remove_block "${_PROXY_OPENRC_CONF_DIR}/${svc}"
    done
}
