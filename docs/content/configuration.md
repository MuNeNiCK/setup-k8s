# Configuration

## Container runtime

containerd is the default runtime:

```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- init
```

Use CRI-O:

```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  init --cri crio
```

Joining nodes must use the same CRI as the existing cluster.

## Kubernetes version

Pin a Kubernetes minor or patch version:

```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  init --kubernetes-version 1.33.2
```

## Proxy mode

`setup-k8s` supports three kube-proxy modes.

| Mode | Use when | Notes |
|---|---|---|
| `iptables` | Default, broad compatibility | Good for small and medium clusters |
| `ipvs` | Many services or high service traffic | Requires IPVS kernel modules and `ipvsadm`/`ipset` |
| `nftables` | Large clusters on Kubernetes 1.29+ | Alpha in 1.29-1.30, beta in 1.31+ |

IPVS:

```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  init --proxy-mode ipvs
```

nftables:

```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  init --proxy-mode nftables --kubernetes-version 1.31
```

If prerequisites are not met, the script exits with an error.

## Swap support

By default, `setup-k8s` disables swap. This is required for Kubernetes versions before 1.28.

Starting with Kubernetes 1.28, the `NodeSwap` feature gate allows nodes to run with swap enabled. Use `--swap-enabled` to keep swap active and configure kubelet with `failSwapOn: false` and `memorySwap.swapBehavior: LimitedSwap`.

```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  init --swap-enabled --kubernetes-version 1.32
```

For remote deployment:

```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sh -s -- \
  deploy \
  --control-planes 10.0.0.1 \
  --workers 10.0.0.2 \
  --swap-enabled
```

Requirements:

- Kubernetes 1.28 or higher.
- Swap must already be configured by the OS.

## Generic binary install

When running on an unsupported distribution, or when `--distro generic` is specified, `setup-k8s` downloads binaries directly instead of using a package manager.

Downloaded components:

- kubeadm, kubelet, and kubectl from `dl.k8s.io`.
- containerd and runc from GitHub Releases.
- CNI plugins from GitHub Releases.
- CRI-O from release tarballs.

Binaries are installed to `/usr/local/bin/`, and CNI plugins are installed to `/opt/cni/bin/`.

```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  init --distro generic --kubernetes-version 1.32
```

Override component versions with environment variables:

```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | \
  sudo CONTAINERD_VERSION=2.0.4 RUNC_VERSION=1.2.5 sh -s -- init --distro generic
```

Supported generic architectures are `amd64` and `arm64`.

## kubeadm configuration

Append custom kubeadm YAML with `--kubeadm-config-patch`:

```bash
setup-k8s.sh deploy \
  --control-planes 10.0.0.1 \
  --kubeadm-config-patch custom-config.yaml \
  --ssh-key ~/.ssh/id_rsa
```

The patch is appended as an additional YAML document to the generated kubeadm config.

Add API server SANs:

```bash
setup-k8s.sh deploy \
  --control-planes 10.0.0.1 \
  --api-server-extra-sans lb.example.com,10.0.0.200 \
  --ssh-key ~/.ssh/id_rsa
```

Set a kubelet node IP:

```bash
setup-k8s.sh deploy \
  --control-planes 10.0.0.1 \
  --kubelet-node-ip 10.0.0.1 \
  --ssh-key ~/.ssh/id_rsa
```

## SSH security

Use `--ssh-password-file` instead of `--ssh-password` to avoid exposing passwords in the process list:

```bash
setup-k8s.sh deploy \
  --control-planes 10.0.0.1 \
  --ssh-password-file /run/secrets/ssh-pass
```

The file must have mode `0600` or stricter.

Persist known hosts:

```bash
setup-k8s.sh deploy \
  --control-planes 10.0.0.1 \
  --persist-known-hosts ./known_hosts
```

Reuse them with strict checking:

```bash
setup-k8s.sh upgrade \
  --control-planes 10.0.0.1 \
  --ssh-known-hosts ./known_hosts
```
