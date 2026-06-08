# High Availability

`setup-k8s` supports highly available control planes using [kube-vip](https://kube-vip.io/) for Virtual IP management.

kube-vip runs as a static pod on each control-plane node and provides a floating VIP using ARP-based leader election.

## How it works

1. During `init`, the script writes `/etc/kubernetes/manifests/kube-vip.yaml` before running `kubeadm init`.
2. The control-plane endpoint is set to `<VIP>:6443` unless `--control-plane-endpoint` is provided.
3. After initialization, kubeadm uploads certificates and the script displays the join command for additional control-plane nodes.
4. Additional control-plane nodes join with `setup-k8s.sh join --control-plane`.

## Flags

| Flag | Description | Required |
|---|---|---|
| `--ha` | Enable HA mode for local `init` | Yes for local HA init |
| `--ha-vip ADDRESS` | Virtual IP address | Yes |
| `--ha-interface IFACE` | Interface that owns the VIP | No, auto-detected |

For remote `deploy`, `--ha-vip` enables HA mode.

## Initialize the first control-plane node

```bash
curl -fsSL https://github.com/MuNeNiCK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  init \
  --ha \
  --ha-vip 192.168.1.100 \
  --pod-network-cidr 192.168.0.0/16
```

## Join additional control-plane nodes

```bash
curl -fsSL https://github.com/MuNeNiCK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  join \
  --control-plane \
  --certificate-key <certificate-key> \
  --ha-vip 192.168.1.100 \
  --join-token <token> \
  --join-address 192.168.1.100:6443 \
  --discovery-token-hash <hash>
```

## Join workers

```bash
curl -fsSL https://github.com/MuNeNiCK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  join \
  --join-token <token> \
  --join-address 192.168.1.100:6443 \
  --discovery-token-hash <hash>
```

## Requirements

- The VIP must be unused and reachable on the same subnet as the control-plane nodes.
- The interface is auto-detected from the default route when `--ha-interface` is omitted.
- containerd and CRI-O are both supported.
