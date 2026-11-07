#!/bin/sh

# Cluster configuration file (--config FILE) for the commands that work on
# a cluster over SSH: deploy, upgrade, remove, backup, restore, renew.
#
# The file defines the cluster: the nodes and their roles, SSH access, and
# the options a deploy uses. Its keys are the option names, grouped by
# section (ssh.user is --ssh-user); options given on the command line win.
# It is read without external tools: block mappings, block and flow ([a, b])
# lists, lists of mappings, comments, and quoted scalars. Anything else
# (anchors, block scalars, flow mappings, tabs) is an error, as is an
# unknown key.
#
#   config_load <action> <file> [cli_options]
#                                 Set _CONFIG_ARGS (quoted options for the
#                                 action, except those in cli_options, which
#                                 the command line sets) and _NODE_OVERRIDES
#                                 (per-node SSH port/key and kubelet node IP)
#   node_override <host> <field>  Print a per-node setting (port, key, node-ip)

_CONFIG_ARGS=""
# Lines of "host<TAB>port<TAB>key<TAB>node-ip"
_NODE_OVERRIDES=""

# Print "path<TAB>value" for every scalar of a YAML file (lists of scalars
# joined with commas; list items of mappings numbered: nodes.0.address).
# Fails with a message on constructs it does not read.
_config_flatten() {
    awk '
        function fail(msg) { printf "%s:%d: %s\n", FILENAME, NR, msg > "/dev/stderr"; bad = 1; exit 1 }
        function unquote(v) {
            if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) return substr(v, 2, length(v) - 2)
            return v
        }
        function strip_comment(s,   i, c, q, out) {
            q = ""; out = ""
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                if (q == "" && c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t]/)) break
                if (q == "" && (c == "\"" || c == "\047")) q = c
                else if (c == q) q = ""
                out = out c
            }
            sub(/[ \t]+$/, "", out)
            return out
        }
        function check_value(v) {
            if (v ~ /^[&*!]/) fail("anchors, aliases, and tags are not supported")
            if (v ~ /^[|>]/) fail("block scalars (| and >) are not supported")
            if (v ~ /^\{/) fail("flow mappings ({...}) are not supported")
        }
        function flow_list(v,   n, parts, i, out, item) {
            v = substr(v, 2, length(v) - 2)
            n = split(v, parts, ",")
            out = ""
            for (i = 1; i <= n; i++) {
                item = parts[i]; gsub(/^[ \t]+|[ \t]+$/, "", item)
                if (item == "") continue
                check_value(item)
                out = out (out == "" ? "" : ",") unquote(item)
            }
            return out
        }
        function emit(path, v) {
            if (v ~ /^\[/) { if (v !~ /\]$/) fail("unterminated flow list"); v = flow_list(v) }
            else { check_value(v); v = unquote(v) }
            if (path in seen) fail("duplicate key: " path)
            seen[path] = 1
            print path "\t" v
        }
        # Path of the deepest open mapping with indent < ind
        function parent(ind) {
            while (depth > 0 && indent[depth] >= ind) depth--
            return depth > 0 ? path[depth] : ""
        }
        function join(p, k) { return p == "" ? k : p "." k }
        {
            line = $0
            if (line ~ /^\t/ || line ~ /^ *\t/) fail("tabs are not allowed for indentation")
            line = strip_comment(line)
            if (line ~ /^[ ]*$/) next
            if (line ~ /^---/ || line ~ /^\.\.\./) fail("document markers are not supported")
            match(line, /^ */); ind = RLENGTH; body = substr(line, ind + 1)

            if (body ~ /^- / || body == "-") {
                # List item of the list owned by the key above
                p = parent(ind + 1)
                if (!(p in islist)) fail("list item without a key")
                item = substr(body, 3); gsub(/^ +/, "", item)
                if (item ~ /^[A-Za-z0-9_.-]+:( |$)/) {
                    # Mapping item: nodes.<n>, with its first key on this line
                    idx = count[p]++
                    ip = p "." idx
                    depth++; indent[depth] = ind + 1; path[depth] = ip
                    ind2 = ind + 2
                    body = item; ind = ind2
                } else {
                    if (item == "") fail("empty list item")
                    check_value(item)
                    listval[p] = listval[p] (listval[p] == "" ? "" : ",") unquote(item)
                    next
                }
            }

            if (body !~ /^[A-Za-z0-9_.-]+:( |$)/) fail("expected \"key: value\"")
            key = substr(body, 1, index(body, ":") - 1)
            val = substr(body, index(body, ":") + 1); gsub(/^ +/, "", val)
            p = join(parent(ind), key)
            if (val == "") {
                # Mapping or block list below
                depth++; indent[depth] = ind; path[depth] = p
                islist[p] = 1
                pending[p] = 1
            } else {
                emit(p, val)
            }
        }
        END {
            if (bad) exit 1
            for (p in listval) emit(p, listval[p])
        }' "$1"
}

# Option of a configuration key, for the actions that use it; empty for a
# key that is valid but not used by <action>; "?" for an unknown key.
# Usage: _config_option <action> <key>
_config_option() {
    local action="$1" key="$2" opt="" scope=deploy
    case "$key" in
        ssh.user) opt=--ssh-user scope=all ;;
        ssh.port) opt=--ssh-port scope=all ;;
        ssh.key) opt=--ssh-key scope=all ;;
        ssh.host-key-check) opt=--ssh-host-key-check scope=all ;;
        ssh.known-hosts) opt=--ssh-known-hosts scope=all ;;
        ssh.password-file) opt=--ssh-password-file scope=all ;;
        kubernetes.version) opt=--kubernetes-version scope="deploy upgrade" ;;
        kubernetes.cri) opt=--cri ;;
        kubernetes.image-repository) opt=--image-repository ;;
        kubernetes.patches) opt=--patches scope="deploy upgrade" ;;
        kubernetes.config-patch) opt=--kubeadm-config-patch ;;
        kubernetes.swap-enabled) opt=--swap-enabled ;;
        network.proxy-mode) opt=--proxy-mode ;;
        network.pod-cidr) opt=--pod-network-cidr ;;
        network.service-cidr) opt=--service-cidr ;;
        network.control-plane-endpoint) opt=--control-plane-endpoint ;;
        network.apiserver-cert-extra-sans) opt=--apiserver-cert-extra-sans ;;
        ha.vip) opt=--ha-vip ;;
        ha.interface) opt=--ha-interface ;;
        proxy.http) opt=--http-proxy scope="deploy upgrade" ;;
        proxy.https) opt=--https-proxy scope="deploy upgrade" ;;
        proxy.no-proxy) opt=--no-proxy scope="deploy upgrade" ;;
        tools.helm) opt=--install-helm ;;
        tools.kustomize) opt=--install-kustomize ;;
        tools.completion.enabled) opt=--enable-completion ;;
        tools.completion.shells) opt=--completion-shells ;;
        *) echo "?"; return 0 ;;
    esac
    case " $scope " in
        *" all "*|*" $action "*) echo "$opt" ;;
    esac
}

# Append an option (and value) unless the command line gives it
_config_add() {
    case " $_CONFIG_CLI_OPTS " in *" $1 "*) return 0 ;; esac
    _CONFIG_ARGS="${_CONFIG_ARGS}$(_posix_shell_quote "$1")"
    [ $# -lt 2 ] || _CONFIG_ARGS="${_CONFIG_ARGS}$(_posix_shell_quote "$2")"
}

# Usage: config_load <action> <file> [cli_options]
config_load() {
    local action="$1" file="$2" dir flat tab key value opt node_lines
    _CONFIG_CLI_OPTS="${3:-}"
    if [ ! -f "$file" ]; then
        log_error "Configuration file not found: $file"
        return 1
    fi
    dir=$(cd "$(dirname "$file")" && pwd)
    flat=$(_config_flatten "$file") || { log_error "Cannot read $file (see above)"; return 1; }
    tab=$(printf '\t')
    _CONFIG_ARGS="" _NODE_OVERRIDES=""

    # Options
    while IFS="$tab" read -r key value; do
        [ -n "$key" ] || continue
        case "$key" in nodes.*) continue ;; esac
        opt=$(_config_option "$action" "$key")
        if [ "$opt" = "?" ]; then
            log_error "${file}: unknown key: ${key}"
            return 1
        fi
        [ -n "$opt" ] || continue
        case "$key" in
            ssh.key|ssh.known-hosts|ssh.password-file|kubernetes.patches|kubernetes.config-patch)
                value=$(_config_path "$dir" "$value") ;;
        esac
        case "$opt" in
            --swap-enabled)
                case "$value" in
                    true) _config_add "$opt" ;;
                    false) ;;
                    *) log_error "${file}: ${key} must be true or false"; return 1 ;;
                esac
                ;;
            *) _config_add "$opt" "$value" ;;
        esac
    done <<EOF
$flat
EOF

    # Nodes
    node_lines=$(printf '%s\n' "$flat" | awk -F'\t' '$1 ~ /^nodes\./')
    [ -n "$node_lines" ] || return 0
    printf '%s\n' "$node_lines" | grep -q -E '^nodes\.[^0-9]' && { log_error "${file}: nodes must be a list"; return 1; }
    local n=0 count cps="" workers="" address role user port key nodeip field entry
    count=$(printf '%s\n' "$node_lines" | sed -n 's/^nodes\.\([0-9]*\)\..*/\1/p' | sort -n | tail -n 1)
    while [ "$n" -le "${count:--1}" ]; do
        address="" role="" user="" port="" key="" nodeip=""
        while IFS="$tab" read -r field value; do
            case "$field" in
                "nodes.${n}.address") address="$value" ;;
                "nodes.${n}.role") role="$value" ;;
                "nodes.${n}.node-ip") nodeip="$value" ;;
                "nodes.${n}.ssh.user") user="$value" ;;
                "nodes.${n}.ssh.port") port="$value" ;;
                "nodes.${n}.ssh.key") key=$(_config_path "$dir" "$value") ;;
                "nodes.${n}."*) log_error "${file}: unknown node key: ${field#nodes.${n}.}"; return 1 ;;
            esac
        done <<EOF
$node_lines
EOF
        if [ -z "$address" ]; then
            log_error "${file}: node $((n + 1)) has no address"
            return 1
        fi
        entry="$address"
        [ -n "$user" ] && entry="${user}@${address}"
        case "$role" in
            control-plane) cps="${cps}${cps:+,}${entry}" ;;
            worker) workers="${workers}${workers:+,}${entry}" ;;
            *) log_error "${file}: node ${address}: role must be control-plane or worker"; return 1 ;;
        esac
        if [ -n "${port}${key}${nodeip}" ]; then
            _NODE_OVERRIDES="${_NODE_OVERRIDES}${address}${tab}${port}${tab}${key}${tab}${nodeip}
"
        fi
        n=$((n + 1))
    done

    case "$action" in
        deploy|upgrade)
            [ -n "$cps" ] && _config_add --control-planes "$cps"
            [ -n "$workers" ] && _config_add --workers "$workers"
            ;;
        renew)
            [ -n "$cps" ] && _config_add --control-planes "$cps"
            ;;
        remove|backup|restore)
            # A single control plane runs the command
            [ -n "$cps" ] && _config_add --control-planes "${cps%%,*}"
            ;;
    esac
    return 0
}

# Paths in the file are relative to the file; ~ is the home directory
_config_path() {
    case "$2" in
        /*) echo "$2" ;;
        "~"/*) echo "${HOME}/${2#"~"/}" ;;
        ./*) echo "$1/${2#./}" ;;
        *) echo "$1/$2" ;;
    esac
}

# Usage: node_override <host> <port|key|node-ip>
node_override() {
    [ -n "$_NODE_OVERRIDES" ] || return 0
    local col
    case "$2" in port) col=2 ;; key) col=3 ;; node-ip) col=4 ;; *) return 0 ;; esac
    printf '%s' "$_NODE_OVERRIDES" | awk -F'\t' -v h="$1" -v c="$col" '$1 == h { print $c; exit }'
}
