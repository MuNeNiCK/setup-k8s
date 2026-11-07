# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Version numbers will follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once tagged releases begin.

No tagged releases have been published yet. Changes made before this file was
introduced are recorded in the [git history](https://github.com/MuNeNiCK/setup-k8s/commits/main).

## [Unreleased]

### Added

- `--config FILE` reads the cluster (nodes and roles, SSH access per node,
  cluster options, per-node kubelet node IP) from a YAML file for `deploy`,
  `upgrade`, `remove`, `backup`, `restore`, and `renew`. Read without external
  tools; command-line options replace those of the file.
- Running `deploy` again on an existing cluster adds the listed nodes that
  are not in it yet (control planes and workers); the others are left alone.
- `deploy` saves the admin kubeconfig to `./kubeconfig` (mode 600) on the
  machine it runs on, read with sudo for non-root SSH users (the printed
  `scp` command failed for them). A new cluster is not deployed when the file
  exists.
- HTTP proxy support: `--http-proxy`, `--https-proxy`, `--no-proxy` for
  `init`, `join`, `deploy`, and `upgrade` (default: the proxy environment
  variables). The proxy is used for downloads and the package manager and
  set for the container runtime's image pulls; the cluster's own addresses
  and networks are always excluded. `test/scenarios/proxy.sh` verifies it
  with all other outbound connections blocked.
- A weekly upstream check (`scripts/check-upstream.sh`) opens an issue for
  each upstream change that needs action: new Kubernetes minors and
  prereleases, end of life of tested Kubernetes minors and distributions,
  component updates (patch, minor, major; for containerd, the end of life
  of the pinned minor or a newer LTS minor), and new distribution releases.
  Dependabot updates GitHub Actions.
- `--proxy-mode auto` (the new default): nftables on Kubernetes 1.33+ with
  Linux 5.13+, iptables otherwise. `preflight --proxy-mode auto` shows the
  resolved mode.
- `--kubernetes-version` accepts an exact patch version (`1.37.2`) for
  `init`, `join`, and `deploy`; the control plane is pinned to the installed
  kubeadm version.
- `--prerelease` installs the next Kubernetes release from the prerelease
  channels of pkgs.k8s.io and isv:cri-o.
- `--image-repository REPO` pulls control-plane and pause images from a
  mirror.
- `--patches DIR` passes kubeadm patches to `init`, `join`, and
  `upgrade`; `deploy` and remote `upgrade` copy the directory to every node.
- `preflight` reports user namespace support for Pods and the SELinuxMount
  behavior of Kubernetes 1.37+ (information only).
- `test/scenarios/swap-reboot.sh` checks that swap stays off across reboots.
- `LICENSE` (Apache License 2.0).
- `CHANGELOG.md` to track notable changes.
- `CONTRIBUTING.md` describing the branching model, development requirements,
  and pre-submission checks.
- `scripts/build.sh` builds the single-file bundle `dist/setup-k8s.sh` and its
  sha256 checksum.
- Release workflow: pushing a `v*` tag publishes the bundle and checksum as
  GitHub release assets.
- `--version` prints the setup-k8s version.
- `upgrade --rollback-to VERSION` reinstalls kubeadm, kubelet, and kubectl at
  an earlier version on the local node (used by automatic rollback).
- Distributions not in the supported list are matched by `ID_LIKE` (for
  example Ubuntu derivatives) with a warning.

### Changed

- Kubernetes 1.35+ runs on cgroups v1 nodes (Rocky Linux 8, AlmaLinux 8):
  setup-k8s sets kubelet `failCgroupV1: false` there and warns, instead of
  refusing to install. Rocky Linux 8 and AlmaLinux 8 are tested again;
  Debian 11 (end of regular support) is no longer listed.
- Fedora 43 (end of life 2026-12-01) is no longer tested.
- The full VM matrices run for pull requests into `main` (before a release)
  and on demand, instead of on every push to `develop` and `main` and weekly.
  Every pull request still runs the Ubuntu 24.04 smoke test.
- The VM tests check what each run asks for (Kubernetes version, runtime,
  proxy mode, networking, swap, kubeadm patches, tools, completion, logging),
  that cleanup leaves nothing behind, that the HA VIP serves the API server
  and moves when the leader fails, that renewed certificates are new and
  served, and exact versions after upgrades. Unit tests that only checked
  that functions exist were removed.
- kube-proxy runs in nftables mode by default where the node supports it (see
  `--proxy-mode auto`); use `--proxy-mode iptables` for the previous default.
- containerd 1.x: `preflight` fails for Kubernetes 1.38+ (the first release
  without kubelet support for containerd 1.7) and warns for earlier versions.
  The previous check assumed 1.36.
- `--swap-enabled` requires Kubernetes 1.30+ (NodeSwap is disabled by default
  in 1.28 and 1.29).
- Default versions for `--distro generic`: containerd 2.3.7, runc 1.5.2, CNI
  plugins 1.9.1. kube-vip v1.3.1 (manifest uses `vip_subnet` and
  `vip_nodename`).
- Helm 4.3.1 and Kustomize 5.8.3 are installed as pinned release binaries
  with sha256 verification (`HELM_VERSION`, `KUSTOMIZE_VERSION`) instead of
  running upstream install scripts (Kustomize's from the `master` branch).
- runc downloads are verified against the published checksums.
- `--distro generic` (and `--prerelease`, whose channel has no cri-tools
  package) installs crictl from the cri-tools GitHub release.
- The script is distributed as a GitHub release asset
  (`releases/latest/download/setup-k8s.sh`) instead of being fetched from
  `raw/main`. `curl | sh` downloads one file; modules are no longer downloaded
  individually at runtime.
- Remote subcommands that run setup-k8s on the nodes (`deploy`, and
  `upgrade` / `backup` / `restore` / `renew` with `--control-planes`) must be
  run from a downloaded file. They transfer that file to the nodes.
- Global options (`--dry-run`, `--verbose`, `--quiet`, `--log-dir`,
  `--audit-syslog`, `--collect-diagnostics`, `--resume`) are handled by the
  entry point; all other options are passed unchanged to the subcommand. The
  subcommand must come before its options.
- `setup-k8s.sh --help` lists subcommands and global options;
  `setup-k8s.sh <subcommand> --help` shows subcommand options, including a new
  help page for `init` and `join`.
- Package sources: Kubernetes from pkgs.k8s.io; CRI-O from the `isv:cri-o`
  repository; containerd from the Docker repository (the `rhel` repository for
  RHEL, Rocky, AlmaLinux, and Oracle Linux); containerd on openSUSE Leap from
  `Virtualization:containers`.
- Arch Linux installs Kubernetes from the official repositories instead of the
  AUR. Alpine no longer adds packages from `edge`. On both, the default
  Kubernetes version is the one the distribution ships.
- RPM-based distributions keep Kubernetes packages out of routine upgrades
  with `exclude=` in the repository file (upstream instructions) instead of
  the versionlock plugin.
- The container runtime uses the pause image of the installed kubeadm;
  `PAUSE_IMAGE_VERSION` overrides it.
- `preflight` reports the SELinux mode as information instead of a warning.
  The SELinux mode is not changed; `container-selinux` is installed on
  RPM-based distributions.
- `remove` does not transfer the script to the nodes and also works via
  `curl | sh`.
- Source layout: `lib/` is split into `core/`, `pkg/`, `components/`, `node/`,
  `remote/`, and `cluster/`; `distros/` is removed (distribution-specific
  values live in `lib/core/distro.sh`); `backup` and `restore` share
  `commands/etcd.sh`.
- Unit tests run on bats-core (`bats -r test/unit`) and mirror the source
  layout.

### Fixed

- CRI-O on openSUSE Leap 16 (SELinux enforcing) started no containers:
  the policy did not let systemd attach the eBPF device filters that crun
  creates ("systemd failed to install eBPF device filter"). With SELinux
  enabled, setup-k8s adds a policy module with only that rule
  (`setup-k8s-crio-bpf`); cleanup removes it.
- `upgrade` left CRI-O and its repository on the earlier Kubernetes minor.
  CRI-O now moves to the target minor on each node (and back on rollback)
  and is checked after the restart. dnf and zypper install the newest patch
  of a requested minor (they installed by name, which does not upgrade or
  downgrade an installed package).
- Commands no longer report success without checking the result:
  - `renew` fails without crictl, waits until the control-plane components
    run in new containers and the API server is ready, and checks that each
    renewed certificate expires later than before.
  - `upgrade` checks that the cluster reports the target version for each
    node's kubelet and for the API server, that kubelet stays running, and
    fails when a node stays cordoned. kubeadm's node-readiness checks are
    skipped only while nodes are NotReady (no CNI plugin).
  - `remove` succeeds only when the node object is gone; nodes are found by
    address or hostname, never by guessing the address as the node name.
  - `backup` checks the snapshot with `etcdutl snapshot status` and that the
    copy (or download) is identical; `restore` waits for the API server.
  - `status` exits 1 when kubelet, the container runtime, the API server, or
    etcd does not work and 2 when Kubernetes is not set up (always 0 before).
  - `cleanup` checks for leftovers independently of the removal steps
    (packages, holds and locks, repositories and keys, binaries, kubelet
    configuration), removes all distribution packages of the install on
    Alpine and Arch (cri-tools/crictl and cni-plugins were left), and
    releases the kube-vip VIP. It no longer deletes the containerd init
    script of the distribution package (Alpine), which broke the next install.
    With CRI-O, the cluster is reset before CRI-O stops: the control-plane
    containers kept running after cleanup.
  - HA `init` fails when the control-plane certificates cannot be uploaded;
    CRI-O is restarted to load its configuration and must be running; host
    preparation checks cgroups and shared mount propagation.
- `--audit-syslog` had no effect on `init`, `join`, `cleanup`, and local
  `upgrade`: they now write started, completed, and failed records.
- `--kubeadm-config-patch` with a `KubeletConfiguration` or
  `KubeProxyConfiguration` together with `--swap-enabled` or `--proxy-mode`
  made kubeadm reject the config (two documents of one kind); such documents
  are now merged.
- `init` and `join` with `--dry-run` installed base packages, refreshed the
  package indexes, and prepared the host before printing "no changes made".
- Remote commands (deploy, upgrade, backup, restore, renew): a command that
  finished at the last poll was reported as a timeout, a remote process that
  died without an exit status was only noticed at the timeout, and the exit
  status file could be read before it was written.
- `deploy` reported success when the API server or etcd was unhealthy after
  the joins, and could fail because a node object appeared a few seconds
  after `kubeadm join` returned. It now requires the API server, etcd, and
  every node to be registered (waiting up to 2 minutes for registration);
  NotReady nodes and Pending CoreDNS before a CNI plugin is installed are
  reported, not failures. `--resume` no longer joins workers again that
  already joined.
- Swap came back after a reboot when it was enabled by a systemd swap unit
  that is not in `/etc/fstab` (for example a swap file unit), so kubelet did
  not start. All systemd swap units now get a drop-in that keeps them from
  starting; `cleanup` removes it.
- CRI-O installation on RHEL-family and SUSE distributions (the
  pkgs.k8s.io CRI-O repository is no longer served).
- Automatic upgrade rollback, which was always rejected as a downgrade.
- Upgrades install the exact requested patch version on every package manager.
- `--kubelet-node-ip` on RPM packages (written to `/etc/sysconfig/kubelet`).
- `cleanup` on Debian 13 and Ubuntu: held packages were not detected as
  installed and were left behind.
- Version checks for proxy modes and kube-vip no longer mis-evaluate because
  of shell operator precedence; the kubeadm config API falls back to
  `v1beta4`.
- `--resume` is no longer reset to false when running from a source checkout.

### Security

- Binary downloads fail when the published sha256 checksum cannot be fetched
  or does not match (verification was previously skipped silently).

[Unreleased]: https://github.com/MuNeNiCK/setup-k8s/commits/develop
