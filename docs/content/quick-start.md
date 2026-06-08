# Quick Start

## Initialize a single-node cluster

```bash
curl -fsSL https://github.com/MuNeNiCK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- init
```

Install a CNI plugin after initialization:

```bash
kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml
```

For a single-node cluster, allow workloads on the control-plane node:

```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

## Join a worker

Get the join command details from the control-plane node:

```bash
kubeadm token create --print-join-command
```

Then run `setup-k8s` on the worker:

```bash
curl -fsSL https://github.com/MuNeNiCK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  join \
  --join-token <token> \
  --join-address <address> \
  --discovery-token-hash <hash>
```

## Deploy multiple nodes over SSH

```bash
curl -fsSL https://github.com/MuNeNiCK/setup-k8s/raw/main/setup-k8s.sh | sh -s -- \
  deploy \
  --control-planes root@192.168.1.10 \
  --workers root@192.168.1.11,root@192.168.1.12
```

## Deploy an HA cluster

```bash
curl -fsSL https://github.com/MuNeNiCK/setup-k8s/raw/main/setup-k8s.sh | sh -s -- \
  deploy \
  --control-planes root@192.168.1.10,root@192.168.1.11,root@192.168.1.12 \
  --workers root@192.168.1.20 \
  --ha-vip 192.168.1.100
```

## Check status

```bash
curl -fsSL https://github.com/MuNeNiCK/setup-k8s/raw/main/setup-k8s.sh | sh -s -- status
```

Use `wide` output for cluster-level details:

```bash
curl -fsSL https://github.com/MuNeNiCK/setup-k8s/raw/main/setup-k8s.sh | sh -s -- status --output wide
```

## Clean up

```bash
curl -fsSL https://github.com/MuNeNiCK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- cleanup --force
```
