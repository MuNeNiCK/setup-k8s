# Backup and Restore

The `backup` and `restore` subcommands manage etcd snapshots for kubeadm clusters.

Both commands support local execution on a control-plane node and remote orchestration over SSH.

## How backup works

Backup creates an etcd snapshot with `etcdctl snapshot save` inside the running etcd container via `crictl exec`.

The snapshot is saved through etcd's hostPath mount and copied to the requested output path.

## How restore works

Restore extracts `etcdctl` and `etcdutl` from the etcd container image, then:

1. Moves the etcd static pod manifest to stop etcd.
2. Backs up the existing `/var/lib/etcd` directory.
3. Runs `etcdutl snapshot restore` for etcd 3.6+ or `etcdctl snapshot restore` for etcd 3.5.
4. Restores the manifest to restart etcd.
5. Waits for etcd health checks.

A cleanup handler restores the etcd manifest if restore fails mid-operation.

## Local backup

```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  backup --snapshot-path /path/to/snapshot.db
```

Use the default auto-generated path:

```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- backup
```

## Local restore

```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sudo sh -s -- \
  restore --snapshot-path /path/to/snapshot.db
```

## Remote backup

```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sh -s -- \
  backup \
  --control-planes root@192.168.1.10 \
  --ssh-key ~/.ssh/id_rsa \
  --snapshot-path ./etcd-snapshot.db
```

## Remote restore

```bash
curl -fsSL https://github.com/MuNeNICK/setup-k8s/raw/main/setup-k8s.sh | sh -s -- \
  restore \
  --control-planes root@192.168.1.10 \
  --ssh-key ~/.ssh/id_rsa \
  --snapshot-path ./etcd-snapshot.db
```

## etcd compatibility

| etcd Version | Backup | Restore Tool |
|---|---|---|
| 3.5.x | `etcdctl snapshot save` | `etcdctl snapshot restore` |
| 3.6.x+ | `etcdctl snapshot save` | `etcdutl snapshot restore` |

## Requirements

- The target node must be a kubeadm control-plane node with etcd running as a static pod.
- Remote mode requires SSH access with passwordless sudo.
- The node must have enough disk space for the snapshot and temporary etcd data backup.
