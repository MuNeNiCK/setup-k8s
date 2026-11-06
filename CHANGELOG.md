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

- Source layout: `lib/` is split into `core/`, `components/`, `node/`,
  `remote/`, and `cluster/`; `backup` and `restore` share `commands/etcd.sh`.
- Unit tests run on bats-core (`bats -r test/unit`) and mirror the source
  layout.

### Fixed

- `--resume` is no longer reset to false when running from a source checkout.

[Unreleased]: https://github.com/MuNeNiCK/setup-k8s/commits/develop
