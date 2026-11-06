# Troubleshooting

## Installation Issues
- Check kubelet logs:
```bash
journalctl -xeu kubelet
```
- Verify system requirements
- Confirm network connectivity
- Check distribution-specific logs for package management issues

## Worker Node Join Issues
- Verify network connectivity
- Check token expiration (24-hour default)
- Confirm firewall settings

## IPVS Mode Issues
- Check kernel module availability:
```bash
lsmod | grep ip_vs
```
- Verify ipvsadm is installed:
```bash
which ipvsadm
```
- Check kube-proxy mode:
```bash
kubectl get configmap -n kube-system kube-proxy -o yaml | grep mode
```
- View IPVS rules:
```bash
sudo ipvsadm -Ln
```

## kubelet does not start after a reboot (swap)

kubelet exits at startup while swap is on (`running with swap on is not supported`). setup-k8s keeps swap off across reboots by commenting out fstab swap entries, adding a drop-in to every systemd swap unit (`/etc/systemd/system/<unit>.swap.d/90-setup-k8s-swap-off.conf`), and disabling zram swap.

Swap that is enabled outside these mechanisms (for example `swapon` in a boot script) still comes back. Check:
```bash
swapon --show
systemctl list-units --type=swap --all
journalctl -u kubelet -b | grep -i swap
```

Nodes set up with an earlier version of setup-k8s may only have had fstab swap entries disabled; run `sudo swapoff -a` and disable the remaining swap unit (`sudo systemctl mask <unit>` or a drop-in as above), or rerun `init` after `cleanup`.

## nftables Mode Issues
- Check kernel module availability:
```bash
lsmod | grep nf_tables
```
- Verify nft is installed:
```bash
which nft
```
- Check kernel version (kube-proxy nftables mode requires >= 5.13):
```bash
uname -r
```
- View nftables rules:
```bash
sudo nft list ruleset
```
- Check the mode kube-proxy runs in (with the default `--proxy-mode auto`, `init` prints the selected mode):
```bash
kubectl -n kube-system get configmap kube-proxy -o jsonpath='{.data.config\.conf}' | grep '^mode'
```
- If a CNI plugin or tool requires iptables rules, reinstall the node with `--proxy-mode iptables`.
- If NodePort services are not accessible:
  - nftables mode only allows NodePort on default IPs
  - Use the node's primary IP address, not 127.0.0.1

## CNI Plugin Issues

### Flannel: `failed to acquire lease: node "xxx" pod cidr not assigned`

Flannel requires each node to have a Pod CIDR assigned via `node.spec.podCIDR`. This is set automatically when `--pod-network-cidr` is passed to `kubeadm init`, but **is not set by default**.

Other CNI plugins (Calico, Cilium, Weave) have their own IPAM and work without this flag.

If you plan to use Flannel, run init with `--pod-network-cidr`:
```bash
setup-k8s.sh init --pod-network-cidr 10.244.0.0/16
```

If the cluster is already initialized without it, you can patch the node manually:
```bash
kubectl patch node <node-name> -p '{"spec":{"podCIDR":"10.244.0.0/24","podCIDRs":["10.244.0.0/24"]}}'
```

> **Note:** The manual patch only assigns a CIDR to existing nodes. For automatic allocation on new nodes (e.g., worker join), the controller-manager must be reconfigured with `--cluster-cidr` and `--allocate-node-cidrs=true`.

## Cleanup Issues
- Ensure proper node drainage
- Verify permissions
- Check system logs:
```bash
journalctl -xe
```

## Distribution Detection Issues
If the script fails to detect your distribution correctly:
- Check if `/etc/os-release` exists and contains valid information
- Distributions not listed in [Supported Distros](supported-distros.md) are matched by `ID_LIKE` (for example, an Ubuntu derivative is handled like Ubuntu) with a warning
- Unknown distributions fall back to release binaries (`--distro generic`)

## SELinux
setup-k8s does not change the SELinux mode. On RPM-based distributions it installs `container-selinux`, and `preflight` reports the current mode for information. If a workload or CNI plugin you install later requires it, switch to permissive mode yourself (`setenforce 0` and `SELINUX=permissive` in `/etc/selinux/config`).

## Distribution-Specific Notes

### Debian/Ubuntu
- Uses apt; Kubernetes packages are held with `apt-mark hold`

### RHEL/CentOS/Fedora
- Uses dnf (dnf4 or dnf5) or yum
- Kubernetes packages are excluded from routine upgrades with `exclude=` in the repository file, as in the upstream instructions; setup-k8s lifts the exclude only for its own installs and upgrades

### SUSE
- Uses zypper; Kubernetes packages are locked with `zypper addlock`
- SLES may require subscription for repositories

### Alpine Linux
- Uses apk for package management
- Uses OpenRC instead of systemd; cgroup manager is set to `cgroupfs`
- Community repository is automatically enabled for Kubernetes packages
- Check kubelet logs with `rc-service kubelet status` or `/var/log/kubelet.log`
- `--ignore-preflight-errors=SystemVerification` is automatically added to kubeadm commands
- Kubernetes comes from Alpine packages, so the available version depends on the Alpine release (for example, Kubernetes 1.34 on Alpine 3.23). Without `--kubernetes-version`, that version is used; requesting another version fails with the available one in the message

### Arch Linux
- Uses pacman and the official Arch repositories (kubeadm, kubelet, kubectl, containerd, cri-o)
- Arch provides only the current Kubernetes version, so versions cannot be pinned and the default is the packaged version
- Installing packages performs a full system upgrade (`pacman -Syu`, kernels excluded), as Arch does not support partial upgrades
