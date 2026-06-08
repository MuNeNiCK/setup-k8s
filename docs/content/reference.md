# Option Reference

## setup-k8s.sh

```
Usage: setup-k8s.sh <init|join|deploy|upgrade|remove|backup|restore|cleanup|renew|status|preflight> [options]
```

### Subcommands

| Subcommand | Description |
|------------|-------------|
| `init` | Initialize a new Kubernetes cluster |
| `join` | Join an existing cluster as a worker or control-plane node |
| `deploy` | Deploy a cluster across remote nodes via SSH |
| `upgrade` | Upgrade cluster Kubernetes version |
| `remove` | Remove nodes from an existing cluster via SSH |
| `backup` | Create an etcd snapshot |
| `restore` | Restore etcd from a snapshot |
| `cleanup` | Remove Kubernetes components from the local node |
| `renew` | Renew or check kubeadm-managed certificates |
| `status` | Show cluster and node status |
| `preflight` | Run preflight checks before init/join |

### Global Options

These options apply to all subcommands and are parsed before subcommand-specific arguments.

| Option | Description | Default | Example |
|--------|-------------|---------|---------|
| `--verbose` | Enable debug logging | — | `--verbose` |
| `--quiet` | Suppress informational messages (errors only) | — | `--quiet` |
| `--dry-run` | Show configuration summary and exit without making changes | — | `--dry-run` |
| `--log-dir DIR` | Persist logs to files in the specified directory | — | `--log-dir /var/log/setup-k8s` |
| `--audit-syslog` | Send structured audit events to syslog via `logger` | — | `--audit-syslog` |
| `--collect-diagnostics` | Collect node diagnostics (kubelet/containerd logs, events) on failure | — | `--collect-diagnostics` |
| `--resume` | Resume a previously interrupted deploy or upgrade operation | — | `--resume` |
| `--distro FAMILY` | Override distro family detection (debian, rhel, suse, arch, alpine, generic) | auto-detect | `--distro alpine` |
| `--help`, `-h` | Display help message | — | `--help` |

### Init/Join Options

| Option | Description | Default | Example |
|--------|-------------|---------|---------|
| `--cri RUNTIME` | Container runtime (containerd or crio) | `containerd` | `--cri crio` |
| `--proxy-mode MODE` | Kube-proxy mode (iptables, ipvs, or nftables) | `iptables` | `--proxy-mode nftables` |
| `--pod-network-cidr CIDR` | Pod network CIDR (IPv4, IPv6, or dual-stack comma-separated) | — | `--pod-network-cidr 10.244.0.0/16,fd00:10:244::/48` |
| `--apiserver-advertise-address ADDR` | API server advertise address | — | `--apiserver-advertise-address 192.168.1.10` |
| `--control-plane-endpoint ENDPOINT` | Control plane endpoint | — | `--control-plane-endpoint cluster.example.com` |
| `--service-cidr CIDR` | Service CIDR (IPv4, IPv6, or dual-stack comma-separated) | — | `--service-cidr 10.96.0.0/12,fd00:20::/108` |
| `--kubernetes-version VER` | Kubernetes version | — | `--kubernetes-version 1.29` |
| `--join-token TOKEN` | Join token (join only) | — | `--join-token abcdef.1234567890abcdef` |
| `--join-address ADDR` | Control plane address (join only) | — | `--join-address 192.168.1.10:6443` |
| `--discovery-token-hash HASH` | Discovery token hash (join only) | — | `--discovery-token-hash sha256:abc...` |
| `--control-plane` | Join as control-plane node (join only, HA cluster) | — | `--control-plane` |
| `--certificate-key KEY` | Certificate key for control-plane join | — | `--certificate-key abc123` |
| `--ha` | Enable HA mode with kube-vip (init only) | — | `--ha` |
| `--ha-vip ADDRESS` | VIP address (required when --ha is set) | — | `--ha-vip 192.168.1.100` |
| `--ha-interface IFACE` | Network interface for VIP | auto-detect | `--ha-interface eth0` |
| `--swap-enabled` | Keep swap enabled (K8s 1.28+, NodeSwap LimitedSwap) | — | `--swap-enabled` |
| `--enable-completion BOOL` | Enable shell completion setup | `true` | `--enable-completion false` |
| `--completion-shells LIST` | Shells to configure (auto, bash, zsh, fish, or comma-separated) | `auto` | `--completion-shells bash,zsh` |
| `--install-helm BOOL` | Install Helm package manager | `false` | `--install-helm true` |
| `--install-kustomize BOOL` | Install Kustomize | `false` | `--install-kustomize true` |

### SSH Options (shared)

These options are shared across all remote subcommands: `deploy`, `upgrade`, `remove`, `backup`, `restore`, and `renew`.

| Option | Description | Default | Example |
|--------|-------------|---------|---------|
| `--ssh-user USER` | Default SSH user | `root` | `--ssh-user ubuntu` |
| `--ssh-port PORT` | SSH port | `22` | `--ssh-port 2222` |
| `--ssh-key PATH` | Path to SSH private key (auto-discovered from `~/.ssh/` when omitted: `id_ed25519` > `id_rsa` > `id_ecdsa`) | auto-discover | `--ssh-key ~/.ssh/id_rsa` |
| `--ssh-password PASS` | SSH password (prefer `--ssh-password-file` or `DEPLOY_SSH_PASSWORD` env var) | — | `--ssh-password secret` |
| `--ssh-password-file PATH` | Read SSH password from file (file must have mode 0600) | — | `--ssh-password-file /run/secrets/ssh-pass` |
| `--ssh-known-hosts FILE` | Pre-seeded known_hosts file for SSH host key verification (implies `--ssh-host-key-check yes`) | — | `--ssh-known-hosts ~/.ssh/known_hosts` |
| `--ssh-host-key-check MODE` | SSH host key verification policy (`yes`, `no`, or `accept-new`) | `accept-new` | `--ssh-host-key-check yes` |
| `--persist-known-hosts PATH` | Save session known_hosts to file after operation (reusable with `--ssh-known-hosts` next time) | — | `--persist-known-hosts ./known_hosts` |
| `--remote-timeout SECS` | Timeout for remote operations in seconds | `600` | `--remote-timeout 900` |
| `--poll-interval SECS` | Poll interval for remote operation progress in seconds | `10` | `--poll-interval 5` |

### Deploy Options

Options specific to the `deploy` subcommand. Init/join options like `--cri`, `--proxy-mode`, `--kubernetes-version`, `--pod-network-cidr`, `--service-cidr`, and `--control-plane-endpoint` are passed through to remote nodes.

| Option | Description | Default | Example |
|--------|-------------|---------|---------|
| `--control-planes IPs` | Comma-separated control-plane nodes (user@ip or ip) | — (required) | `--control-planes 10.0.0.1,10.0.0.2` |
| `--workers IPs` | Comma-separated worker nodes (user@ip or ip) | — | `--workers 10.0.0.3,10.0.0.4` |
| `--ha-vip ADDRESS` | VIP for HA (required when >1 control-plane) | — | `--ha-vip 10.0.0.100` |
| `--ha-interface IFACE` | Network interface for VIP | auto-detect | `--ha-interface eth0` |
| `--kubeadm-config-patch FILE` | Extra kubeadm config YAML to append (merged as additional `---` document) | — | `--kubeadm-config-patch custom.yaml` |
| `--api-server-extra-sans NAMES` | Additional SANs for the API server certificate (comma-separated) | — | `--api-server-extra-sans lb.example.com,10.0.0.200` |
| `--kubelet-node-ip IP` | Set kubelet `--node-ip` on all nodes | — | `--kubelet-node-ip 10.0.0.1` |

### Upgrade Options (local mode)

Options for the `upgrade` subcommand when run locally with `sudo`.

| Option | Description | Default | Example |
|--------|-------------|---------|---------|
| `--kubernetes-version VER` | Target version in MAJOR.MINOR.PATCH format | — (required) | `--kubernetes-version 1.33.2` |
| `--first-control-plane` | Run `kubeadm upgrade apply` (first CP only) | — | `--first-control-plane` |
| `--skip-drain` | Skip drain/uncordon | — | `--skip-drain` |

### Upgrade Options (remote mode)

Options for the `upgrade` subcommand when orchestrating remotely via SSH.

| Option | Description | Default | Example |
|--------|-------------|---------|---------|
| `--control-planes IPs` | Comma-separated control-plane nodes (user@ip or ip) | — (required) | `--control-planes 10.0.0.1,10.0.0.2` |
| `--workers IPs` | Comma-separated worker nodes (user@ip or ip) | — | `--workers 10.0.0.3,10.0.0.4` |
| `--kubernetes-version VER` | Target version in MAJOR.MINOR.PATCH format | — (required) | `--kubernetes-version 1.33.2` |
| `--skip-drain` | Skip drain/uncordon for all nodes | — | `--skip-drain` |
| `--no-rollback` | Disable automatic rollback on upgrade failure | — | `--no-rollback` |
| `--auto-step-upgrade` | Automatically step through intermediate minor versions (e.g., 1.31 → 1.32 → 1.33) | — | `--auto-step-upgrade` |

### Remove Options

Options for the `remove` subcommand. Removes nodes from an existing cluster via SSH.

| Option | Description | Default | Example |
|--------|-------------|---------|---------|
| `--control-planes IPs` | Control-plane node to orchestrate from | — (required) | `--control-planes 10.0.0.1` |
| `--workers IPs` | Comma-separated nodes to remove | — (required) | `--workers 10.0.0.3,10.0.0.4` |

### Backup Options (local mode)

Options for the `backup` subcommand when run locally with `sudo`.

| Option | Description | Default | Example |
|--------|-------------|---------|---------|
| `--snapshot-path PATH` | Output snapshot file path | `/var/lib/etcd-backup/snapshot-YYYYMMDD-HHMMSS.db` | `--snapshot-path /tmp/snap.db` |

### Backup Options (remote mode)

Options for the `backup` subcommand when orchestrating remotely via SSH.

| Option | Description | Default | Example |
|--------|-------------|---------|---------|
| `--control-planes IP` | Target control-plane node (user@ip or ip) | — (required) | `--control-planes root@10.0.0.1` |
| `--snapshot-path PATH` | Local path to save the downloaded snapshot | `/var/lib/etcd-backup/snapshot-YYYYMMDD-HHMMSS.db` | `--snapshot-path ./snap.db` |

### Restore Options (local mode)

Options for the `restore` subcommand when run locally with `sudo`.

| Option | Description | Default | Example |
|--------|-------------|---------|---------|
| `--snapshot-path PATH` | Snapshot file to restore | — (required) | `--snapshot-path /tmp/snap.db` |

### Restore Options (remote mode)

Options for the `restore` subcommand when orchestrating remotely via SSH.

| Option | Description | Default | Example |
|--------|-------------|---------|---------|
| `--control-planes IP` | Target control-plane node (user@ip or ip) | — (required) | `--control-planes root@10.0.0.1` |
| `--snapshot-path PATH` | Local snapshot file to upload and restore | — (required) | `--snapshot-path ./snap.db` |

### Renew Options (local mode)

Options for the `renew` subcommand when run locally on a control-plane node with `sudo`.

| Option | Description | Default | Example |
|--------|-------------|---------|---------|
| `--certs CERTS` | Certificates to renew (`all` or comma-separated names) | `all` | `--certs apiserver,front-proxy-client` |
| `--check-only` | Check certificate expiration only (no renewal) | — | `--check-only` |

Valid certificate names: `apiserver`, `apiserver-kubelet-client`, `front-proxy-client`, `apiserver-etcd-client`, `etcd-healthcheck-client`, `etcd-peer`, `etcd-server`, `admin.conf`, `controller-manager.conf`, `scheduler.conf`, `super-admin.conf`.

### Renew Options (remote mode)

Options for the `renew` subcommand when orchestrating remotely via SSH.

| Option | Description | Default | Example |
|--------|-------------|---------|---------|
| `--control-planes IPs` | Comma-separated control-plane nodes (user@ip or ip) | — (required) | `--control-planes 10.0.0.1,10.0.0.2` |
| `--certs CERTS` | Certificates to renew (`all` or comma-separated names) | `all` | `--certs apiserver,etcd-server` |
| `--check-only` | Check certificate expiration only (no renewal) | — | `--check-only` |

### Status Options

Options for the `status` subcommand. Runs locally without root privileges (read-only operations only). Gracefully skips kubectl-based checks if kubectl is not configured.

| Option | Description | Default | Example |
|--------|-------------|---------|---------|
| `--output FORMAT` | Output format (`text` or `wide`) | `text` | `--output wide` |

**text mode** displays: node role, service status (kubelet, containerd, crio), installed versions, `kubectl get nodes`, and `kubectl get pods -n kube-system`.

**wide mode** additionally displays: API server endpoint, Pod/Service CIDR, and etcd endpoint health.

### Preflight Options

Options for the `preflight` subcommand. Runs locally with root privileges to verify system requirements before `init` or `join`.

| Option | Description | Default | Example |
|--------|-------------|---------|---------|
| `--mode MODE` | Check mode (`init` or `join`) | `init` | `--mode join` |
| `--cri RUNTIME` | Container runtime to check (`containerd` or `crio`) | `containerd` | `--cri crio` |
| `--proxy-mode MODE` | Proxy mode to check (`iptables`, `ipvs`, or `nftables`) | `iptables` | `--proxy-mode ipvs` |
| `--preflight-strict` | Treat warnings as failures (exit non-zero on any warning) | — | `--preflight-strict` |

Checks performed: CPU count (>= 2), memory (>= 1700 MB), disk space, required port availability, kernel modules, IPv4 forwarding, CRI installation, swap state, cgroups v2, SELinux state, AppArmor state, unattended upgrades detection, existing cluster detection (init only), and network connectivity.

### Cleanup Options

| Option | Description | Default | Example |
|--------|-------------|---------|---------|
| `--force` | Skip confirmation prompt | — | `--force` |
| `--preserve-cni` | Preserve CNI configurations | — | `--preserve-cni` |
| `--remove-helm` | Remove Helm binary and configuration | — | `--remove-helm` |
| `--remove-kustomize` | Remove Kustomize binary and configuration | — | `--remove-kustomize` |
| `--dry-run` | Show cleanup plan and exit | — | `--dry-run` |
