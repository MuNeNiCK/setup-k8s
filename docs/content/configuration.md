# Configuration

## Container runtime

containerd is the default runtime:

```bash
curl -fsSL https://github.com/MuNeNiCK/setup-k8s/releases/latest/download/setup-k8s.sh | sudo sh -s -- init
```

Use CRI-O:

```bash
curl -fsSL https://github.com/MuNeNiCK/setup-k8s/releases/latest/download/setup-k8s.sh | sudo sh -s -- \
  init --cri crio
```

Joining nodes must use the same CRI as the existing cluster.

## Kubernetes version

`--kubernetes-version` takes a minor version (the latest patch release of that minor is installed) or an exact patch version:

```bash
curl -fsSL https://github.com/MuNeNiCK/setup-k8s/releases/latest/download/setup-k8s.sh | sudo sh -s -- \
  init --kubernetes-version 1.37      # latest 1.37.x
curl -fsSL https://github.com/MuNeNiCK/setup-k8s/releases/latest/download/setup-k8s.sh | sudo sh -s -- \
  init --kubernetes-version 1.37.2    # exactly 1.37.2
```

Without the option, the latest stable release is installed (on Alpine and Arch: the version the distribution ships).

The control plane runs the same version as the installed kubeadm; kubeadm does not look up a newer patch release online.

### Prerelease versions

`--prerelease` installs the next Kubernetes release (alpha, beta, or release candidate) from the prerelease channels of pkgs.k8s.io and `isv:cri-o`:

```bash
curl -fsSL https://github.com/MuNeNiCK/setup-k8s/releases/latest/download/setup-k8s.sh | sudo sh -s -- \
  init --prerelease                         # latest prerelease
curl -fsSL https://github.com/MuNeNiCK/setup-k8s/releases/latest/download/setup-k8s.sh | sudo sh -s -- \
  init --prerelease --kubernetes-version 1.38
```

The prerelease channel has no cri-tools package, so crictl is installed from the cri-tools GitHub release. Prereleases are for testing only. `--prerelease` is not available on distributions that install Kubernetes from distribution packages (Alpine, Arch); use `--distro generic` there.

## Proxy mode

`setup-k8s` supports these kube-proxy modes.

| Mode | Use when | Notes |
|---|---|---|
| `auto` | Default | `nftables` on Kubernetes 1.33+ with Linux 5.13+ (kube-proxy's requirement), otherwise `iptables` |
| `nftables` | Recommended for new clusters | GA in Kubernetes 1.33; requires Linux 5.13+ |
| `iptables` | Older kernels, or CNI plugins and tools that expect iptables rules | Broad compatibility |
| `ipvs` | Existing clusters already using IPVS | Deprecated in Kubernetes 1.35+ and planned for removal; requires IPVS kernel modules and `ipvsadm`/`ipset` |

The selected mode is printed during `init`. Kubernetes also plans to make nftables the kube-proxy default; `auto` follows that direction where the node supports it.

Set the mode explicitly:

```bash
curl -fsSL https://github.com/MuNeNiCK/setup-k8s/releases/latest/download/setup-k8s.sh | sudo sh -s -- \
  init --proxy-mode iptables
```

If the prerequisites of an explicitly requested mode are not met, the script exits with an error. Check a node in advance with `preflight --proxy-mode auto` (it prints the mode `auto` resolves to).

Notes for nftables mode:

- Some CNI plugins and network policy tools still assume iptables rules; check your CNI documentation.
- NodePort services are only reachable on the node's default IP addresses (not on `127.0.0.1`).

## Swap support

By default, `setup-k8s` disables swap, because kubelet does not start while swap is on. Swap stays off across reboots:

- swap entries in `/etc/fstab` are commented out (a backup is kept in `/etc/fstab.pre-k8s`);
- every systemd swap unit (for example a swap file unit created by the administrator or cloud-init) gets a drop-in that keeps it from starting;
- zram swap (zram-generator, used by Fedora and others) is disabled.

`cleanup` restores all of these.

Use `--swap-enabled` to keep swap active and configure kubelet with `failSwapOn: false` and `memorySwap.swapBehavior: LimitedSwap` (NodeSwap, enabled by default since Kubernetes 1.30 and GA in 1.34):

```bash
curl -fsSL https://github.com/MuNeNiCK/setup-k8s/releases/latest/download/setup-k8s.sh | sudo sh -s -- \
  init --swap-enabled
```

For remote deployment:

```bash
curl -fsSLO https://github.com/MuNeNiCK/setup-k8s/releases/latest/download/setup-k8s.sh
sh setup-k8s.sh \
  deploy \
  --control-planes 10.0.0.1 \
  --workers 10.0.0.2 \
  --swap-enabled
```

Requirements:

- Kubernetes 1.30 or higher.
- Swap must already be configured by the OS.

## Generic binary install

When running on an unsupported distribution, or when `--distro generic` is specified, `setup-k8s` downloads binaries directly instead of using a package manager.

Downloaded components:

- kubeadm, kubelet, and kubectl from `dl.k8s.io`.
- crictl from the cri-tools GitHub release of the same minor version.
- containerd and runc from GitHub Releases.
- CNI plugins from GitHub Releases.
- CRI-O from release tarballs.

Binaries are installed to `/usr/local/bin/`, and CNI plugins are installed to `/opt/cni/bin/`.

```bash
curl -fsSL https://github.com/MuNeNiCK/setup-k8s/releases/latest/download/setup-k8s.sh | sudo sh -s -- \
  init --distro generic --kubernetes-version 1.32
```

Override component versions with environment variables:

```bash
curl -fsSL https://github.com/MuNeNiCK/setup-k8s/releases/latest/download/setup-k8s.sh | \
  sudo CONTAINERD_VERSION=2.4.2 RUNC_VERSION=1.5.2 sh -s -- init --distro generic
```

Downloads are verified against the published sha256 checksums; an install stops if the checksum cannot be verified.

## Pause image

The container runtime is configured with the pause image of the installed kubeadm (`kubeadm config images list`). Set `PAUSE_IMAGE_VERSION` to override the tag:

```bash
sudo PAUSE_IMAGE_VERSION=3.10.2 sh setup-k8s.sh init
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

The patch is merged into the generated kubeadm config. A document of a kind
that setup-k8s also generates (`InitConfiguration`, `ClusterConfiguration`,
`KubeProxyConfiguration` with `--proxy-mode`, `KubeletConfiguration` with
`--swap-enabled`) is merged into that document: its top-level fields replace
the generated ones (a nested block such as `networking:` is replaced as a
whole). Documents of other kinds are added as they are.

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

### kubeadm patches

`--kubeadm-patches DIR` passes a directory of kubeadm patches (`kubeadm --patches`) to `init`, `join`, and `upgrade`. Patches change the generated manifests of the control-plane components, etcd, the kubelet configuration, CoreDNS, and kube-proxy (for example `kube-apiserver+strategic.yaml` or `kubeproxydaemonset+json.json`); see the [kubeadm documentation](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/control-plane-flags/#patches) for file names.

```bash
sudo sh setup-k8s.sh init --kubeadm-patches /etc/setup-k8s/patches
```

With `deploy` and remote `upgrade`, the local directory is copied to every node. Use the same patches for `upgrade` as for `init` and `join`; `kubeadm upgrade` regenerates the manifests.

### Image repository

`--image-repository REPO` pulls the control-plane images (and the pause image) from a mirror instead of `registry.k8s.io`:

```bash
sudo sh setup-k8s.sh init --image-repository registry.example.com/k8s
```

The mirror must provide the images listed by `kubeadm config images list` for the installed version.

## Helm and Kustomize

`--install-helm true` and `--install-kustomize true` install pinned release binaries to `/usr/local/bin/` after verifying their sha256 checksums. Override the versions with `HELM_VERSION` and `KUSTOMIZE_VERSION`:

```bash
sudo HELM_VERSION=4.3.1 KUSTOMIZE_VERSION=5.8.3 sh setup-k8s.sh init --install-helm true --install-kustomize true
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
