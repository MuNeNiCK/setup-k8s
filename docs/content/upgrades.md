# Upgrades

The `upgrade` subcommand automates Kubernetes upgrades following kubeadm upgrade procedures.

It supports local node-by-node execution and remote orchestration over SSH.

## Constraints

- Target version must be `MAJOR.MINOR.PATCH`, for example `1.33.2`.
- Kubernetes only supports `+1` minor version upgrades at a time.
- Patch upgrades within the same minor version are allowed.
- Downgrades are not supported.

## Local mode

Run on the first control-plane node:

```bash
curl -fsSL https://github.com/MuNeNiCK/setup-k8s/releases/latest/download/setup-k8s.sh | sudo sh -s -- \
  upgrade --kubernetes-version 1.33.2 --first-control-plane
```

Run on additional control-plane nodes and workers:

```bash
curl -fsSL https://github.com/MuNeNiCK/setup-k8s/releases/latest/download/setup-k8s.sh | sudo sh -s -- \
  upgrade --kubernetes-version 1.33.2
```

For a single-node cluster:

```bash
curl -fsSL https://github.com/MuNeNiCK/setup-k8s/releases/latest/download/setup-k8s.sh | sudo sh -s -- \
  upgrade --kubernetes-version 1.33.2 --first-control-plane --skip-drain
```

## Remote mode

```bash
curl -fsSLO https://github.com/MuNeNiCK/setup-k8s/releases/latest/download/setup-k8s.sh
sh setup-k8s.sh \
  upgrade \
  --control-planes 10.0.0.1,10.0.0.2 \
  --workers 10.0.0.3,10.0.0.4 \
  --kubernetes-version 1.33.2 \
  --ssh-key ~/.ssh/id_rsa
```

Remote flow:

1. Transfer setup-k8s.sh to all nodes.
2. Check current cluster version and validate upgrade constraints.
3. Run `kubeadm upgrade plan`.
4. Drain, upgrade, and uncordon each control-plane node.
5. Drain, upgrade, and uncordon each worker node.
6. Verify cluster state with `kubectl get nodes`.

## Automatic rollback

Remote upgrade records the kubeadm version of each node before upgrading it. If a node upgrade fails, the node runs `setup-k8s.sh upgrade --rollback-to <previous version>`, which reinstalls kubeadm, kubelet, and kubectl at that version and restarts kubelet; the node is then uncordoned. kubeadm restores its own control-plane manifests when `kubeadm upgrade` fails.

The same command can be run manually on a node:

```bash
sudo sh setup-k8s.sh upgrade --rollback-to 1.36.6
```

Disable rollback for debugging:

```bash
setup-k8s.sh upgrade \
  --control-planes 10.0.0.1 \
  --kubernetes-version 1.33.2 \
  --no-rollback
```

## Multi-version upgrades

Use `--auto-step-upgrade` to upgrade across multiple minor versions:

```bash
setup-k8s.sh upgrade \
  --control-planes 10.0.0.1,10.0.0.2 \
  --kubernetes-version 1.33.2 \
  --auto-step-upgrade \
  --ssh-key ~/.ssh/id_rsa
```

The script computes intermediate steps and runs a full cluster upgrade plus health check for each step.
