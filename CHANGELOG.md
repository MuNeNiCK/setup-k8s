# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Version numbers will follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once tagged releases begin.

No tagged releases have been published yet. Changes made before this file was
introduced are recorded in the [git history](https://github.com/MuNeNiCK/setup-k8s/commits/main).

## [Unreleased]

### Added

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
