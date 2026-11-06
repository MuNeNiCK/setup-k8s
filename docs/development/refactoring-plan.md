# Refactoring Plan

Status: agreed on 2026-11-06. This document records the decisions for the
restructuring of setup-k8s and the order in which they are implemented.
It is a development document and is not part of the published MkDocs site.

## Goals

- Distribute a single, versioned, checksum-verified script.
- Make distribution-specific knowledge live in exactly one place, so adding a
  distribution touches one file.
- Implement each operation (package installation, repository setup, remote
  execution) once instead of once per distribution or per subcommand.
- Test modules through their interfaces with a maintained test framework.

## Decisions

### Distribution and execution

| Topic | Decision |
|---|---|
| Distribution | GitHub release assets. Pushing a `v*` tag builds `dist/setup-k8s.sh` and its `.sha256` and attaches them to the release. |
| First version | `v0.1.0` |
| Install URL | `https://github.com/MuNeNiCK/setup-k8s/releases/latest/download/setup-k8s.sh`. Compatibility with the previous `raw/main/setup-k8s.sh` URL is not kept. |
| `dist/` | Build output only; listed in `.gitignore`. |
| Root `setup-k8s.sh` | Development entry point. It sources `lib/` and dispatches the subcommand. If `lib/` is missing (for example when piped from `raw/main`), it prints the release URL and exits. |
| Execution modes | Two modes only: local checkout (source all modules in a fixed order) and bundle (modules embedded). Per-subcommand module selection and per-module downloads are removed. |
| Remote subcommands | `deploy` and `remove`, and `upgrade`, `backup`, `restore`, and `renew` when given `--control-planes`, must be run from a downloaded file, which is then transferred to the nodes. When run via `curl \| sh`, they print the download instructions and exit. Local subcommands keep working via `curl \| sh`. |
| CLI parsing | The entry point extracts only the subcommand and global flags and passes the remaining arguments unchanged. Each subcommand owns its options and `--help`; the global help lists subcommands only. |

### Package sources

Upstream sources are preferred. Distribution packages are used only where no
upstream repository exists or where the upstream source does not support the
distribution.

| Distribution | Package manager | Kubernetes | containerd | CRI-O |
|---|---|---|---|---|
| Ubuntu, Debian | apt | pkgs.k8s.io | Docker (`linux/ubuntu`, `linux/debian`) | isv:cri-o |
| Fedora | dnf | pkgs.k8s.io | Docker (`linux/fedora`) | isv:cri-o |
| CentOS Stream | dnf | pkgs.k8s.io | Docker (`linux/centos`) | isv:cri-o |
| RHEL, Rocky, AlmaLinux, Oracle Linux | dnf | pkgs.k8s.io | Docker (`linux/rhel`) | isv:cri-o |
| openSUSE Tumbleweed | zypper | pkgs.k8s.io | distribution package | isv:cri-o |
| openSUSE Leap 16 | zypper | pkgs.k8s.io | OBS `Virtualization:containers` | isv:cri-o |
| Alpine | apk | distribution package | distribution package | distribution package |
| Arch | pacman | distribution package (extra) | distribution package | distribution package |
| Other | detected | upstream binaries | upstream binaries | upstream tarball |

Consequences:

- The AUR helper for Arch is removed.
- Alpine no longer falls back to the `edge` repository; the Kubernetes version
  is limited to what the Alpine release provides.
- RPM version pinning follows the upstream instructions (`exclude=` in the
  repository definition, lifted with `--disableexcludes` / `disable_excludes`
  during installs).

### Distribution handling

- There is no `distros/` directory.
- `lib/core/distro.sh` is the only file that knows distribution names. It
  detects the distribution (`ID`, `ID_LIKE`, version) and sets plain values:
  package manager, Kubernetes / containerd / CRI-O sources, Docker repository
  path, codename, and package-name differences.
- Other layers never test distribution names. They branch only on the package
  manager, the package source, the package format (deb / rpm), or observed
  state (init system, missing files or kernel modules, active zram).
- Package-manager behavior, including version differences of the tool itself
  (for example dnf4 / dnf5), belongs to `lib/pkg/<manager>.sh`.

### SELinux

- The SELinux mode is not changed.
- `container-selinux` is installed explicitly on RPM-based distributions.
- The preflight SELinux check reports the mode as INFO instead of WARN.

### Testing and linting

- Unit tests use [bats-core](https://github.com/bats-core/bats-core). Test files
  mirror the `lib/` and `commands/` layout and are discovered automatically.
- External commands (`apt-get`, `dnf`, `ssh`, `kubeadm`, `systemctl`, ...) are
  replaced by fake commands on `PATH`. Tests assert on the commands that were
  run, not on internal functions.
- Code under test can be executed with `dash` from bats to check POSIX
  compatibility.
- VM scenarios keep docker-vm-runner and share one scenario runner; scenario
  files contain only their steps.
- ShellCheck stays. `.shellcheckrc` is reduced to `disable=SC3043` (`local` is
  supported by all target shells). The few dynamic `source` statements in the
  loader use inline `# shellcheck source=/dev/null` directives.

## Target layout

```
setup-k8s.sh                 development entry point
scripts/
  build.sh                   builds dist/setup-k8s.sh (embeds the version)
lib/
  core/
    bootstrap.sh             module load order, exit handlers
    log.sh
    util.sh                  CSV, quoting, user home, confirmation prompt
    defaults.sh              global defaults
    system.sh                architecture, init system, services, machine-id, mount propagation
    download.sh              downloads with mandatory sha256 verification
    validate.sh              CIDR / IP / value format checks
    distro.sh                distribution detection and per-distribution values (only place)
    k8s_version.sh           version resolution, comparison, feature-to-minimum-version table
  pkg/
    pkg.sh                   interface: refresh, install, hold, unhold, remove, repo_add, repo_remove, installed
    apt.sh  dnf.sh  zypper.sh  apk.sh  pacman.sh
  components/
    kubernetes.sh            sources: pkgs.k8s.io / distribution / binary
    cri.sh                   shared runtime handling (socket, crictl)
    containerd.sh            sources: Docker / distribution / OBS / binary
    crio.sh                  sources: isv:cri-o / distribution / binary
    cni.sh                   CNI plugins for binary installs
    kube_vip.sh
    tools.sh                 helm, kustomize
    completion.sh
  node/
    kernel.sh                modules, sysctl, iptables reset
    swap.sh
    kubeadm.sh               kubeadm config generation, join command parsing
  remote/
    run.sh                   interface: remote_session_open, remote_run, remote_exec, remote_session_close
    ssh.sh
    args.sh                  SSH and node options
    session.sh
    bundle.sh                transfers the running script to nodes
  cluster/
    upgrade.sh  etcd.sh  health.sh  state.sh  diagnostics.sh
commands/
  init.sh  join.sh  cleanup.sh  deploy.sh  upgrade.sh  remove.sh
  etcd.sh                    backup and restore
  renew.sh  status.sh  preflight.sh
test/
  unit/                      bats tests mirroring lib/ and commands/
    helpers/                 common setup and fake commands
  scenarios/                 VM end-to-end scenarios
  lib/                       VM harness and shared scenario runner
  matrices/
docs/                        unchanged, plus development documents
```

Dependency direction: `commands` → `cluster` / `remote` / `node` /
`components` → `pkg` → `core`. Values from `core/distro.sh` are read by
`components`, `node`, and `pkg`.

## Implementation phases

Each phase is a separate branch from `develop` and a separate pull request.
Tests for the modules touched in a phase are rewritten in that phase.

| Phase | Scope | Resolves |
|---|---|---|
| 1. Distribution and entry point | Release workflow and `scripts/build.sh`; two execution modes; thin entry point with global-flag parsing; remote subcommands require a file; version string and `--version`; README install URLs | Unpinned per-module downloads from `main`; help drift between entry point and subcommands |
| 2. Layout and test framework | Move modules to the target layout; merge etcd commands; remove `lib/runners.sh`; adopt bats-core with fake commands; reduce `.shellcheckrc` | Hand-maintained module lists and test registration |
| 3. Distribution handling | `core/distro.sh`, `pkg/`, `components/` per the source table; remove `distros/`; SELinux changes | CRI-O repository on RHEL / SUSE; patch versions not pinned on upgrade; `--kubelet-node-ip` on RPM distributions; Arch AUR; Alpine `edge` |
| 4. Remote execution | `remote/run.sh` interface; forward original arguments minus orchestrator-only flags | Upgrade rollback that cannot succeed; duplicated passthrough handling |
| 5. Kubernetes version handling | `core/k8s_version.sh`; derive the pause image and CNI version from the Kubernetes release | Scattered version thresholds; hard-coded pause image |

## Open items

- Check whether enabling EPEL and CRB on CentOS Stream 9 is still required; remove it if not.
- Add Leap 16 with `Virtualization:containers` to the distro test matrix.
