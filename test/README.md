# setup-k8s Test Suite

This directory contains VM-based tests for `setup-k8s.sh`. VM lifecycle is handled by
[`docker-vm-runner`](https://github.com/MuNeNiCK/docker-vm-runner) through the
published `ghcr.io/munenick/docker-vm-runner:latest` image.

E2E scenarios live under `scenarios/`. Root-level `run-*` wrappers are intentionally
not kept.

## Runner Image IDs

Tests accept docker-vm-runner image IDs directly. setup-k8s does not keep a copy of
the docker-vm-runner catalog or any alias map.

The default distro matrix is [matrices/distro-cloud-images.txt](matrices/distro-cloud-images.txt).
Each requested ID is validated with `docker-vm-runner --dry-run` before a VM is started.

```bash
docker run --rm ghcr.io/munenick/docker-vm-runner:latest --list-distros --type cloud-image
```

## Commands

```bash
cd test

./scenarios/init-cleanup.sh --help
./scenarios/init-cleanup.sh ubuntu-24.04-cloud-amd64
./scenarios/init-cleanup.sh --all
./scenarios/init-cleanup.sh --online ubuntu-24.04-cloud-amd64   # uses the published release asset
```

By default scenarios build the single-file bundle with `scripts/build.sh` and
run it with `sh` on the VMs; host-side commands (deploy, upgrade, remove, ...)
run the same bundle.

Subcommand scenarios:

```bash
./scenarios/deploy-remove.sh --distro ubuntu-24.04-cloud-amd64
./scenarios/join.sh --distro ubuntu-24.04-cloud-amd64
./scenarios/preflight.sh --distro ubuntu-24.04-cloud-amd64
./scenarios/backup-restore.sh --distro ubuntu-24.04-cloud-amd64
./scenarios/cert-renew.sh --distro ubuntu-24.04-cloud-amd64
./scenarios/swap-reboot.sh --distro ubuntu-24.04-cloud-amd64   # swap stays off across reboots
./scenarios/options.sh --distro ubuntu-24.04-cloud-amd64       # patch version, image repository, kubeadm patches, Helm, Kustomize
./scenarios/proxy.sh --distro ubuntu-24.04-cloud-amd64          # through an HTTP proxy, all other outbound HTTP(S) blocked
./scenarios/upgrade.sh --deploy-args "--cri crio"                # CRI-O follows the Kubernetes minor
./scenarios/upgrade.sh --distro ubuntu-24.04-cloud-amd64
./scenarios/upgrade.sh --distro ubuntu-24.04-cloud-amd64 --upgrade-args "--skip-drain --no-rollback"
./scenarios/generic.sh --host-distro ubuntu-24.04-cloud-amd64
./scenarios/ha.sh --distro ubuntu-24.04-cloud-amd64
./scenarios/ha.sh --failover --distro ubuntu-24.04-cloud-amd64
```

## GitHub Actions Coverage

| Workflow | Runs on | Coverage |
| --- | --- | --- |
| `ShellCheck & Unit Tests` | pull requests and pushes to `main` and `develop` | ShellCheck, actionlint, and the bats unit tests. |
| `Setup Option Tests` | every pull request (Ubuntu 24.04 smoke test); pull requests to `main` and manual runs (full matrix) | The setup/remove lifecycle across the setup option matrix (`matrices/kubernetes-minors.txt`). |
| `Setup Distro Tests` | pull requests to `main`; manual runs | The setup/remove lifecycle across `matrices/distro-cloud-images.txt`. |
| `Scenario Tests` | pull requests to `main`; manual runs | Join, preflight, deploy/remove, backup/restore, cert renew, upgrade, swap persistence, init options, generic, HA, proxy, and CRI-O upgrade checks. |
| `Upstream Check` | weekly; manual runs | Opens an issue per upstream change that needs action (`scripts/check-upstream.sh`). |
| `docs` | pull requests and pushes to `main` that change `docs/` | Builds the site; deploys it from `main`. |
| `Release` | `v*` tags | Builds and publishes the release asset. |

The full VM matrices run before a release, for the pull request from `develop`
into `main`, and on demand (Actions > the workflow > Run workflow, for example
on `develop` before merging a risky change). A newer push to a pull request
cancels its running VM workflows. Run the matching scenarios locally while
developing (see above).

## Configuration

| Variable | Default |
| --- | --- |
| `DOCKER_VM_RUNNER_IMAGE` | `ghcr.io/munenick/docker-vm-runner:latest` |
| `VM_DATA_DIR` | `test/data` |
| `VM_GUEST_IP6` | unset |
| `TEST_DISTRO_MATRIX_FILE` | `test/matrices/distro-cloud-images.txt` |
| `SKIP_RUNNER_DRY_RUN` | unset |

Resource flags:

```bash
./scenarios/init-cleanup.sh --memory 8192 --cpus 4 --disk-size 40G ubuntu-24.04-cloud-amd64
./scenarios/init-cleanup.sh --guest-ip6 fd00:10:2::15/64 --setup-args "--pod-network-cidr fd00:10:244::/48 --service-cidr fd00:20::/108 --apiserver-advertise-address __VM_IP6__ --control-plane-endpoint [__VM_IP6__]:6443 --kubelet-node-ip __VM_IP6__" ubuntu-24.04-cloud-amd64
```

## Artifacts

Test output is written under `test/results/`. VM cache and working disks are stored
under `test/data/`.

## Maintenance

Refresh the distro matrix when the
[`docker-vm-runner`](https://github.com/MuNeNiCK/docker-vm-runner) repository
or published image changes the available catalog IDs.

```bash
docker pull ghcr.io/munenick/docker-vm-runner:latest
docker run --rm ghcr.io/munenick/docker-vm-runner:latest --list-distros --type cloud-image
```
