# Cluster File

The commands that work on a cluster over SSH (`deploy`, `upgrade`, `remove`,
`backup`, `restore`, `renew`) can read the cluster from a file instead of
command-line options:

```bash
sh setup-k8s.sh deploy --config cluster.yaml
```

The file lists the nodes and their roles, the SSH access, and the cluster
options. Keep it next to the cluster's `kubeconfig` and pass it to every
command: add nodes by extending `nodes` and running `deploy` again, upgrade
by changing `kubernetes.version` and running `upgrade`. setup-k8s does not
make the cluster match the file on its own: `deploy` adds the listed nodes
that are missing, nodes removed from the list stay until you run `remove`,
and `deploy` does not change the version of existing nodes.

## Example

Options left at their default are commented out.

```yaml
nodes:
  - address: 10.0.0.1
    role: control-plane
  - address: 10.0.0.2
    role: control-plane
  - address: 10.0.0.3
    role: control-plane
  - address: 10.0.0.11
    role: worker
  - address: 10.0.0.12
    role: worker
    # node-ip: 192.168.10.12      # default: the address kubelet picks
    # ssh:                         # default: the ssh section below
    #   user: admin
    #   port: 2222
    #   key: ~/.ssh/id_admin

ssh:
  user: ubuntu                     # default: root
  key: ~/.ssh/id_ed25519           # default: the SSH default keys or ssh-agent
  # port: 22
  # host-key-check: accept-new     # yes / accept-new / no
  # known-hosts: ~/.ssh/known_hosts

kubernetes:
  version: "1.37"                  # default: latest stable; upgrade moves to this version
  # cri: containerd                # containerd / crio
  # image-repository: registry.k8s.io
  # patches: ./kubeadm-patches     # relative to this file
  # config-patch: ./kubeadm-patch.yaml
  # swap-enabled: false

network:
  # proxy-mode: auto               # auto / nftables / iptables / ipvs
  # pod-cidr: 10.244.0.0/16        # default: not set
  # service-cidr: 10.96.0.0/12
  # control-plane-endpoint: 10.0.0.100:6443   # default: the first control plane (HA: the VIP)
  # apiserver-cert-extra-sans: []

ha:                                # needed with more than one control plane
  vip: 10.0.0.100
  # interface: eth0                # default: detected

# proxy:                           # default: no proxy
#   http: http://proxy.example.com:3128
#   https: http://proxy.example.com:3128
#   no-proxy: []                   # the cluster's addresses are always added

# tools:
#   helm: false
#   kustomize: false
#   completion:
#     enabled: true
#     shells: [auto]               # auto / bash / zsh / fish
```

## Keys

A key and its section name make the option name (`ssh.user` is
`--ssh-user`). The exceptions:

| Key | Option |
|---|---|
| `kubernetes.config-patch` | `--kubeadm-config-patch` |
| `network.pod-cidr` | `--pod-network-cidr` |
| `proxy.http`, `proxy.https` | `--http-proxy`, `--https-proxy` |
| `tools.helm`, `tools.kustomize` | `--install-helm`, `--install-kustomize` |
| `tools.completion.enabled`, `tools.completion.shells` | `--enable-completion`, `--completion-shells` |
| `nodes[].role` | `--control-planes` / `--workers` |
| `nodes[].node-ip` | `--kubelet-node-ip`, for that node only |
| `nodes[].ssh.*` | SSH settings for that node only |

- Options given on the command line replace those of the file.
- Each command uses what applies to it: `upgrade` the nodes, SSH settings,
  `kubernetes.version`, `kubernetes.patches`, and `proxy`; `backup`,
  `restore`, and `remove` the first control plane and SSH settings; `renew`
  the control planes and SSH settings. How a run behaves (`--dry-run`,
  `--resume`, `--skip-drain`, `--snapshot-path`, `remove --nodes`, ...) is
  given on the command line only.
- Lists are written as `[a, b]` or as `- a` items. Paths are relative to the
  file; `~` is the home directory.
- The file is read without external tools. Anchors, block scalars (`|`,
  `>`), flow mappings (`{...}`), tabs, and unknown keys are errors.
