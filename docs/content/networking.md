# Networking

## Pod and service CIDRs

Set pod and service CIDRs during initialization:

```bash
curl -fsSL https://github.com/MuNeNiCK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  init \
  --pod-network-cidr 192.168.0.0/16 \
  --service-cidr 10.96.0.0/12
```

## IPv4/IPv6 dual-stack

Pass comma-separated CIDRs, one IPv4 and one IPv6:

```bash
curl -fsSL https://github.com/MuNeNiCK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  init \
  --pod-network-cidr 10.244.0.0/16,fd00:10:244::/48 \
  --service-cidr 10.96.0.0/12,fd00:20::/108
```

## IPv6 single-stack

```bash
curl -fsSL https://github.com/MuNeNiCK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  init \
  --pod-network-cidr fd00:10:244::/48 \
  --service-cidr fd00:20::/108
```

## HA with an IPv6 VIP

IPv6 addresses are supported for `--ha-vip`. The control-plane endpoint is automatically formatted with brackets.

```bash
curl -fsSL https://github.com/MuNeNiCK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  init \
  --ha \
  --ha-vip fd00::100 \
  --pod-network-cidr fd00:10:244::/48
```

## CNI plugin

Install a CNI plugin after `kubeadm init` completes:

```bash
kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml
```

Make sure the CNI plugin supports your address family. Calico, Cilium, and Flannel support dual-stack, but plugin-specific configuration may still be required.

## Single-node clusters

Remove the control-plane taint to run workloads on a single-node cluster:

```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

## Verification

```bash
kubectl get nodes
kubectl get pods --all-namespaces
```
