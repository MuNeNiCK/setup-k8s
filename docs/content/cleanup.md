# Cleanup Guide

## Quick Start

Execute the cleanup subcommand:
```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- cleanup [options]
```

## Worker Node Cleanup

1. Drain the node (run on control-plane):
```bash
kubectl drain <worker-node-name> --ignore-daemonsets
kubectl delete node <worker-node-name>
```

2. Run cleanup on the worker:
```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- cleanup --force
```

## Control-Plane Node Cleanup

**Warning**: This will destroy your entire cluster.

1. Ensure all worker nodes are removed first
2. Run cleanup:
```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- cleanup --force
```

## Options

See [reference.md](reference.md) for the full list of cleanup options.
