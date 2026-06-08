# Documentation

## Pages

- [Overview](content/index.md) - What `setup-k8s` is and when to use it.
- [Quick Start](content/quick-start.md) - Minimal commands for init, join, deploy, HA, status, and cleanup.
- [Installation](content/installation.md) - Local init/join flows, preflight checks, and prerequisites.
- [Remote Deploy](content/remote-deploy.md) - Multi-node deployment from an orchestrator over SSH.
- [Configuration](content/configuration.md) - Runtime, proxy mode, swap, generic installs, kubeadm patches, and SSH security.
- [High Availability](content/high-availability.md) - kube-vip based HA control-plane setup.
- [Networking](content/networking.md) - Pod/service CIDRs, IPv6, dual-stack, CNI, and single-node taints.
- [Operations](content/operations.md) - Status, logging, diagnostics, health checks, and resume behavior.
- [Upgrades](content/upgrades.md) - Local and remote Kubernetes upgrades.
- [Backup and Restore](content/backup-restore.md) - etcd snapshot backup and restore.
- [Certificates](content/certificates.md) - kubeadm certificate checks and renewal.
- [Cleanup](content/cleanup.md) - Remove Kubernetes state from workers or control-plane nodes.
- [Supported Distros](content/supported-distros.md) - Tested distributions and known limitations.
- [Troubleshooting](content/troubleshooting.md) - Common installation, CNI, cleanup, and distro issues.
- [Reference](content/reference.md) - Complete CLI option reference.

## Local Preview

```bash
cd docs
python -m pip install -r requirements.txt
mkdocs serve
```
