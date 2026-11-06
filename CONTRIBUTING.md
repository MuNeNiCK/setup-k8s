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
| `setup-k8s.sh` | Entry point: global flag parsing and subcommand dispatch |
| `lib/` | Shared modules (validation, logging, SSH, bundling, kubeadm config, ...) |
| `commands/` | Subcommand implementations (`init`, `join`, `deploy`, `upgrade`, ...) |
| `distros/<family>/` | Per-distribution logic for `debian`, `rhel`, `suse`, `arch`, `alpine`, `generic` |
| `test/unit/` | Unit tests (`run.sh` is the runner) |
| `test/scenarios/` | VM-based end-to-end scenarios |
| `docs/` | MkDocs documentation site |

## Coding guidelines

- Runtime scripts (`setup-k8s.sh`, `lib/`, `commands/`, `distros/`) must be POSIX
  `sh`. They run under dash, ash, and busybox sh, so avoid bashisms
  (`[[ ]]`, arrays, `${var//}`, `source`, `pipefail`, ...). `local` is allowed;
  see `.shellcheckrc`.
- Test code under `test/` is bash.
- New `lib/` or `commands/` modules must be registered in `_LIB_MODULES` or
  `_COMMAND_MODULES` in `lib/bootstrap.sh`. They are used by the bundled and
  `curl | sh` execution modes.
- Each distribution family implements the same entry points, which are called
  via `_dispatch`:
  `install_dependencies_<family>`, `setup_containerd_<family>`,
  `setup_crio_<family>`, `setup_kubernetes_<family>`,
  `upgrade_kubeadm_<family>`, `upgrade_kubelet_kubectl_<family>`, and
  `cleanup_<family>`.
- Never log secrets such as join tokens, certificate keys, or SSH passwords.
- When adding or changing an option, update the subcommand `--help` text, the
  global help in `setup-k8s.sh`, and `docs/content/reference.md`.

## Checks before opening a pull request

### ShellCheck

CI uses ShellCheck 0.11.0 and fails on warnings:

```sh
shellcheck -s sh -S warning setup-k8s.sh lib/*.sh commands/*.sh distros/*/*.sh
shellcheck -s bash -S warning test/scenarios/*.sh test/unit/*.sh test/lib/*.sh
```

### Unit tests

```sh
bash test/unit/run.sh
```

Every `test/unit/*.sh` file is sourced automatically, but each test function
must also be called from `test/unit/run.sh`.

### VM scenario tests (recommended for behavior changes)

Scenarios run real VMs through
[docker-vm-runner](https://github.com/MuNeNiCK/docker-vm-runner) and require
Docker and KVM (`/dev/kvm`). See [test/README.md](test/README.md) for details.

```sh
cd test
./scenarios/init-cleanup.sh ubuntu-24.04-cloud-amd64
./scenarios/init-cleanup.sh --setup-args "--proxy-mode nftables" debian-13-cloud-amd64
```

When a change affects a specific distribution family or subcommand, run the
matching scenario on that distribution.

### Documentation

If you changed anything under `docs/`, check that the site builds:

```sh
python -m pip install -r docs/requirements.txt
mkdocs build --config-file docs/mkdocs.yml --strict
```

## Changelog

Add an entry for user-visible changes under `## [Unreleased]` in
[CHANGELOG.md](CHANGELOG.md), using the `Added`, `Changed`, `Deprecated`,
`Removed`, `Fixed`, and `Security` sections.

## License

By contributing, you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE), as described in Section 5 of the license.
