# Certificates

The `renew` subcommand manages kubeadm-managed certificate expiration checks and renewal.

Kubeadm certificates expire after one year by default. Expired certificates can prevent the cluster from functioning.

## Check expiration

```bash
curl -fsSL https://github.com/MuNeNiCK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  renew --check-only
```

## Renew all certificates

```bash
curl -fsSL https://github.com/MuNeNiCK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- renew
```

After renewal, control-plane static pod components are restarted with `crictl stop`. Kubelet restarts the stopped containers, and the script waits for the API server to become ready.

## Renew specific certificates

```bash
curl -fsSL https://github.com/MuNeNiCK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  renew --certs apiserver,front-proxy-client
```

## Remote check

```bash
curl -fsSL https://github.com/MuNeNiCK/setup-k8s/raw/main/setup-k8s.sh | sh -s -- \
  renew \
  --control-planes root@192.168.1.10,root@192.168.1.11 \
  --ssh-key ~/.ssh/id_rsa \
  --check-only
```

## Remote renewal

```bash
curl -fsSL https://github.com/MuNeNiCK/setup-k8s/raw/main/setup-k8s.sh | sh -s -- \
  renew \
  --control-planes root@192.168.1.10,root@192.168.1.11 \
  --ssh-key ~/.ssh/id_rsa
```

Remote nodes are processed sequentially to avoid restarting every API server at once.

## Valid certificate names

| Name | Description |
|---|---|
| `apiserver` | API server serving certificate |
| `apiserver-kubelet-client` | API server to kubelet client certificate |
| `front-proxy-client` | Front proxy client certificate |
| `apiserver-etcd-client` | API server to etcd client certificate |
| `etcd-healthcheck-client` | etcd health check client certificate |
| `etcd-peer` | etcd peer certificate |
| `etcd-server` | etcd serving certificate |
| `admin.conf` | Admin kubeconfig embedded certificate |
| `controller-manager.conf` | Controller manager kubeconfig certificate |
| `scheduler.conf` | Scheduler kubeconfig certificate |
| `super-admin.conf` | Super admin kubeconfig certificate |

## Requirements

- The target node must be a kubeadm control-plane node.
- `crictl` must be available to restart control-plane components.
- Remote mode requires SSH access with passwordless sudo.
