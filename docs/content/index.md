# Overview

`setup-k8s` installs and operates kubeadm-based Kubernetes clusters with a single shell entrypoint.

It supports local single-node setup, manual node joins, SSH-driven multi-node deployment, and HA control planes with kube-vip.

## What you can do

- Initialize a kubeadm control-plane node.
- Join worker and additional control-plane nodes.
- Deploy a full cluster from one orchestrator host over SSH.
- Use containerd or CRI-O.
- Select kube-proxy mode: iptables, IPVS, or nftables.
- Configure IPv4, IPv6, or dual-stack networking.
- Run preflight checks before changing nodes.
- Upgrade clusters, renew certificates, back up etcd, restore etcd, and clean up nodes.

## Entry point

Use the repository script directly:

```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- init
```

For multi-node operations, run without `sudo` on the orchestrator and let the script use SSH to reach the nodes:

```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sh -s -- \
  deploy \
  --control-planes root@192.168.1.10 \
  --workers root@192.168.1.11,root@192.168.1.12
```

## Next step

Start with [Quick Start](quick-start.md), then use [Installation](installation.md) for local node flows or [Remote Deploy](remote-deploy.md) for SSH orchestration.
