# Contributing to setup-k8s

Thank you for your interest in improving setup-k8s. This document describes how
to propose changes and what is checked before they are merged.

## Reporting issues

Open an issue on [GitHub](https://github.com/MuNeNiCK/setup-k8s/issues) and include:

- The command you ran (redact tokens, certificate keys, and passwords).
- Distribution and version (`cat /etc/os-release`).
- Kubernetes version, container runtime (`--cri`), and proxy mode (`--proxy-mode`).
- Output with `--verbose`. `--log-dir DIR` and `--collect-diagnostics` capture
  additional details on failure.

Please do not report security vulnerabilities in public issues. Contact the
maintainer ([@MuNeNiCK](https://github.com/MuNeNiCK)) privately instead.

## Branching model

| Branch | Purpose |
|---|---|
| `main` | Stable branch. Users run `setup-k8s.sh` directly from it via `curl \| sh`, so it must always work. |
| `develop` | Integration branch for the next release. |
| `<type>/<short-description>` | Work branches, created from `develop` (e.g. `fix/rhel-crio-repo`). |

1. Create a work branch from the latest `develop`.
2. Open a pull request against `develop`.
3. `develop` is merged into `main` when it is ready for release.

## Commit messages

Use `<type>: <summary>` with a short, imperative summary. Types used in this
repository:

| Type | Use for |
|---|---|
| `add` | New features or options |
| `fix` | Bug fixes |
| `update` | Changes to existing behavior or version bumps |
| `refactor` | Code changes that do not alter behavior |
| `test` | Unit or VM scenario tests |
| `docs` | Documentation only |
| `chore` | Repository maintenance, CI, tooling |

## Project layout

| Path | Contents |
|---|---|
| `setup-k8s.sh` | Entry point: global flags and subcommand dispatch |
| `scripts/build.sh` | Builds the single-file release bundle `dist/setup-k8s.sh` |
| `lib/core/` | Module loading, defaults, logging, validation, distribution detection and per-distribution values, Kubernetes versions |
| `lib/pkg/` | Package management interface and adapters (apt, dnf, zypper, apk, pacman) |
| `lib/components/` | Installed components (Kubernetes packages, container runtimes, kube-vip, Helm/Kustomize, completion) |
| `lib/node/` | Node configuration (kernel modules and sysctl, swap, kubeadm config) |
| `lib/remote/` | SSH transport, sessions, and script transfer for remote subcommands |
| `lib/cluster/` | Cluster operations (upgrade orchestration, etcd, health, state, diagnostics) |
| `commands/` | Subcommands: argument parsing, help, dry-run, and execution |
| `test/unit/` | bats-core unit tests, mirroring `lib/` and `commands/` |
| `test/scenarios/` | VM-based end-to-end scenarios |
| `docs/` | MkDocs documentation site |

## Coding guidelines

- Runtime scripts (`setup-k8s.sh`, `scripts/`, `lib/`, `commands/`) must be POSIX
  `sh`. They run under dash, ash, and busybox sh, so avoid bashisms
  (`[[ ]]`, arrays, `${var//}`, `source`, `pipefail`, ...). `local` is allowed;
  see `.shellcheckrc`.
- Test code under `test/` is bash (bats for unit tests).
- New `lib/` or `commands/` modules must be added to `_MODULES` in
  `lib/core/bootstrap.sh`. The list defines the source order for both a local
  checkout and the single-file bundle built by `scripts/build.sh`.
- Distribution names are known only by `lib/core/distro.sh`. It sets values
  such as the package manager and the Kubernetes, containerd, and CRI-O
  sources; other modules branch on those values, the package format, or
  observed state (init system, missing files or modules), never on the
  distribution name. Adding a distribution that uses an existing package
  manager means adding it to `lib/core/distro.sh`.
- Package operations go through `lib/pkg/pkg.sh` (`pkg_install`,
  `pkg_repo_add`, ...). Package-manager specifics, including differences
  between versions of the tool, belong in `lib/pkg/<manager>.sh`.
- Behavior that depends on the Kubernetes version uses `k8s_supports <feature>`
  with the minimum versions listed in `lib/core/k8s_version.sh`; do not
  compare version numbers elsewhere.
- Never log secrets such as join tokens, certificate keys, or SSH passwords.
- When adding or changing an option, update the subcommand `--help` text, the
  global help in `setup-k8s.sh`, and `docs/content/reference.md`.

## Checks before opening a pull request

### ShellCheck

CI uses ShellCheck 0.11.0 and fails on warnings:

```sh
shellcheck -s sh -S warning setup-k8s.sh scripts/*.sh lib/*/*.sh commands/*.sh
shellcheck -s bash -S warning test/scenarios/*.sh test/lib/*.sh test/unit/helpers/*.bash
shellcheck -S warning test/unit/*/*.bats
```

### Workflows

If you changed anything under `.github/workflows/`, run
[actionlint](https://github.com/rhysd/actionlint) 1.7 (CI runs it too):

```sh
actionlint
```

Actions are pinned by commit SHA with the release tag as a comment.

### Unit tests

Unit tests use [bats-core](https://github.com/bats-core/bats-core) 1.14:

```sh
bats -r test/unit
```

Each test file loads `test/unit/helpers/common.bash`, which provides
`load_modules` (sources every module, as the entry point does) and
`fake_cmd` (puts a fake external command on `PATH` and records its calls in
`fake_calls`). Prefer asserting on the commands a module runs over testing
internal helper functions.

### VM scenario tests (recommended for behavior changes)

Scenarios run real VMs through
[docker-vm-runner](https://github.com/MuNeNiCK/docker-vm-runner) and require
Docker and KVM (`/dev/kvm`). See [test/README.md](test/README.md) for details.

```sh
cd test
./scenarios/init-cleanup.sh ubuntu-24.04-cloud-amd64
./scenarios/init-cleanup.sh --setup-args "--proxy-mode iptables" debian-13-cloud-amd64
```

When a change affects a specific distribution family or subcommand, run the
matching scenario on that distribution.

On GitHub, pull requests run ShellCheck, actionlint, the unit tests, and an
Ubuntu 24.04 smoke test. These four are required to merge into `main` and
`develop` (enable auto-merge on the pull request to merge once they pass).
The full VM matrices run after merging into `develop` (and again for `main`);
see [test/README.md](test/README.md).

Dependabot proposes GitHub Actions updates against `develop`. A weekly
workflow (`.github/workflows/upstream-check.yml`) opens an issue labeled
`upstream` for each upstream change that needs action, and closes it once the
change is handled:

- a new Kubernetes minor (newer than `test/matrices/kubernetes-minors.txt`)
  or a prerelease of the next minor, with the availability of the
  pkgs.k8s.io, CRI-O, and cri-tools releases for it
- a tested Kubernetes minor or distribution within 60 days of its end of life
- a component default in `lib/core/defaults.sh` with a newer release
  (patch, minor, or major), and a newer containerd minor
- a newer release of a tested distribution in the image catalog, or a test
  image missing from it

Run `sh scripts/check-upstream.sh` to see the current findings.

### Documentation

If you changed anything under `docs/`, check that the site builds:

```sh
python -m pip install -r docs/requirements.txt
mkdocs build --config-file docs/mkdocs.yml --strict
```

## Building and releasing

`scripts/build.sh` writes the single-file bundle `dist/setup-k8s.sh` and its
`.sha256`. Pushing a `v*` tag runs the Release workflow, which builds the
bundle with the tag as its version and attaches both files to a GitHub
release.

```sh
sh scripts/build.sh
sh dist/setup-k8s.sh --version
```

## Changelog

Add an entry for user-visible changes under `## [Unreleased]` in
[CHANGELOG.md](CHANGELOG.md), using the `Added`, `Changed`, `Deprecated`,
`Removed`, `Fixed`, and `Security` sections.

## License

By contributing, you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE), as described in Section 5 of the license.
