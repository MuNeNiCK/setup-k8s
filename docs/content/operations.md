# Operations

## Cluster status

The `status` subcommand performs read-only local checks and does not require `sudo`.

```bash
curl -fsSL https://github.com/MuNeNiCK/setup-k8s/raw/main/setup-k8s.sh | sh -s -- status
```

Use wide output for cluster-level information:

```bash
curl -fsSL https://github.com/MuNeNiCK/setup-k8s/raw/main/setup-k8s.sh | sh -s -- status --output wide
```

Text mode checks:

- Node role.
- kubelet, containerd, and CRI-O service status.
- Installed kubelet, kubeadm, and kubectl versions.
- Cluster nodes and kube-system pods when kubectl is configured.

Wide mode also checks:

- API server endpoint.
- Pod and service CIDRs.
- etcd health on control-plane nodes.

## Logging

Persist logs with `--log-dir`:

```bash
setup-k8s.sh deploy \
  --log-dir /var/log/setup-k8s \
  --control-planes 10.0.0.1 \
  --ssh-key ~/.ssh/id_rsa
```

Log files use timestamped names and mode `0600`.

## Audit logging

Structured audit events are recorded for deploy, upgrade, remove, backup, restore, and renew operations. Events include timestamp, operation, outcome, and user.

When `--log-dir` is set, audit events are written to the log file. Add `--audit-syslog` to send events to syslog via `logger -t setup-k8s`.

## Failure diagnostics

Enable automatic diagnostics collection with `--collect-diagnostics`.

Collected data includes:

- kubelet logs.
- containerd logs.
- recent cluster events.
- disk and memory status.

Diagnostics are saved under `/tmp/setup-k8s-diag-*` on the orchestrator.

## Health checks

Post-operation health checks run after deploy, upgrade, and remove:

- API server readiness.
- Node readiness.
- etcd health and quorum.
- kube-system pod health.

Pre-operation health checks run before upgrade and remove.

## Resume operations

Long-running deploy and upgrade operations can be resumed:

```bash
setup-k8s.sh deploy \
  --resume \
  --control-planes 10.0.0.1,10.0.0.2 \
  --ssh-key ~/.ssh/id_rsa
```

State is stored in `/var/lib/setup-k8s/state/`. Bundle generation and transfer are always re-run because remote temporary directories are cleaned on exit.
