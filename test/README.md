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
./scenarios/init-cleanup.sh --online ubuntu-24.04-cloud-amd64
```

Subcommand scenarios:

```bash
./scenarios/deploy-remove.sh --distro ubuntu-24.04-cloud-amd64
./scenarios/join.sh --distro ubuntu-24.04-cloud-amd64
./scenarios/preflight.sh --distro ubuntu-24.04-cloud-amd64
./scenarios/backup-restore.sh --distro ubuntu-24.04-cloud-amd64
./scenarios/cert-renew.sh --distro ubuntu-24.04-cloud-amd64
./scenarios/upgrade.sh --distro ubuntu-24.04-cloud-amd64
./scenarios/upgrade.sh --distro ubuntu-24.04-cloud-amd64 --upgrade-args "--skip-drain --no-rollback"
./scenarios/generic.sh --host-distro ubuntu-24.04-cloud-amd64
./scenarios/ha.sh --distro ubuntu-24.04-cloud-amd64
./scenarios/ha.sh --failover --distro ubuntu-24.04-cloud-amd64
```

## GitHub Actions Coverage

| Workflow | Coverage |
| --- | --- |
| `ShellCheck & Unit Tests` | Runs shellcheck and unit tests for local scripts. |
| `Setup Option Tests` | Runs the setup/remove lifecycle across the setup option matrix. |
| `Setup Distro Tests` | Runs the setup/remove lifecycle across the distro matrix. |
| `Scenario Tests` | Runs join, preflight, deploy/remove, backup/restore, cert renew, upgrade, generic, and HA checks across the scenario matrix. |

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
