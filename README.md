# Kubernetes Cluster Management Scripts

[![ShellCheck & Unit Tests](https://github.com/MuNeNICK/setup-k8s/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/MuNeNICK/setup-k8s/actions/workflows/shellcheck.yml)
[![docs](https://github.com/MuNeNICK/setup-k8s/actions/workflows/docs.yml/badge.svg)](https://github.com/MuNeNICK/setup-k8s/actions/workflows/docs.yml)

Set up or tear down a Kubernetes cluster with a single command.
Follows the official [kubeadm installation guide](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/).
Distro auto-detection means the same command works on Ubuntu, Rocky Linux, Arch, Alpine, and more.

Supports single-node, multi-node, and HA (high availability) clusters with kube-vip.
Proxy mode, CRI (containerd/CRI-O), version pinning, and many other options are fully configurable.

## Quick Start

### Initialize Cluster
```sh
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- init
```

### Join Cluster
```sh
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  join \
  --join-token <token> \
  --join-address <address> \
  --discovery-token-hash <hash>
```

### Deploy Multi-Node Cluster via SSH
```sh
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sh -s -- \
  deploy \
  --control-planes root@192.168.1.10 \
  --workers root@192.168.1.11,root@192.168.1.12
```

### Deploy HA Cluster
```sh
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sh -s -- \
  deploy \
  --control-planes root@192.168.1.10,root@192.168.1.11,root@192.168.1.12 \
  --workers root@192.168.1.20 \
  --ha-vip 192.168.1.100
```

### Cleanup
```sh
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- cleanup --force
```

## Documentation

| Document | Description |
|----------|-------------|
| [Documentation Index](docs/README.md) | Full docs map and local preview instructions |
| [Quick Start](docs/content/quick-start.md) | Minimal init, join, deploy, HA, status, and cleanup commands |
| [Installation](docs/content/installation.md) | Local init/join examples, preflight checks, prerequisites |
| [Remote Deploy](docs/content/remote-deploy.md) | Multi-node deployment from an orchestrator over SSH |
| [Configuration](docs/content/configuration.md) | Runtime, proxy, swap, generic install, kubeadm, and SSH settings |
| [Operations](docs/content/operations.md) | Status, logging, diagnostics, health checks, and resume behavior |
| [Option Reference](docs/content/reference.md) | All setup-k8s.sh options |
| [Troubleshooting](docs/content/troubleshooting.md) | Common issues and distribution-specific notes |

## Support
- Issues and feature requests: Open an issue in the repository
- Documentation updates: Submit a pull request

## Distribution Test Results

See [Supported Distros](docs/content/supported-distros.md) for tested versions, status meanings, and known limitations.
