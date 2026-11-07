# Supported Distros

Latest full validation: 2026-06-09 with Kubernetes v1.36.1.
Rows dated 2026-11-06 or later were verified with Kubernetes v1.37.2 after the package-source changes (Alpine uses the version it ships: v1.34.2 on 3.23, v1.36.1 on 3.24).

| Distribution | Version | Test Date | Status | Notes |
|---|---|---|---|---|
| Ubuntu | 26.04 LTS | 2026-11-07 | Tested | |
| Ubuntu | 24.04 LTS | 2026-11-06 | Tested | |
| Ubuntu | 22.04 LTS | 2026-06-09 | Tested | |
| Debian | 13 (Trixie) | 2026-11-06 | Tested | |
| Debian | 12 (Bookworm) | 2026-06-09 | Tested | |
| RHEL | 9 | - | Untested | Subscription required |
| RHEL | 8 | - | Untested | Subscription required |
| CentOS Stream | 10 | 2026-06-09 | Tested | |
| CentOS Stream | 9 | 2026-06-09 | Tested | |
| Rocky Linux | 10 | 2026-06-09 | Tested | |
| Rocky Linux | 9 | 2026-11-07 | Tested | Verified with CRI-O |
| Rocky Linux | 8 | 2026-11-07 | Tested | cgroups v1 (see [cgroups v1](#cgroups-v1)) |
| AlmaLinux | 10 | 2026-06-09 | Tested | |
| AlmaLinux | 9 | 2026-06-09 | Tested | |
| AlmaLinux | 8 | 2026-11-07 | Tested | cgroups v1 (see [cgroups v1](#cgroups-v1)) |
| Oracle Linux | 9 | 2026-06-09 | Tested | |
| Fedora | 45 | 2026-11-07 | Tested | Verified with containerd and CRI-O |
| Fedora | 44 | 2026-11-06 | Tested | |
| openSUSE | Tumbleweed | 2026-06-09 | Tested | |
| openSUSE | Leap 16.0 | 2026-11-07 | Tested | containerd from Virtualization:containers; verified with CRI-O (SELinux module, see [CRI-O](#cri-o-and-selinux)) |
| SLES | 15 SP5 | - | Untested | Subscription required |
| Alpine Linux | 3.24 | 2026-11-07 | Tested | OpenRC, cgroupfs; Kubernetes 1.36 (distribution package) |
| Alpine Linux | 3.23 | 2026-11-06 | Tested | OpenRC, cgroupfs; Kubernetes 1.34 (distribution package) |
| Arch Linux | Rolling | 2026-11-06 | Tested | Official repositories (no AUR) |
| Manjaro | Rolling | - | Untested | No cloud image |

## Package sources

| Distribution | Package manager | Kubernetes | containerd | CRI-O |
|---|---|---|---|---|
| Ubuntu, Debian | apt | pkgs.k8s.io | Docker repository | isv:cri-o |
| Fedora, CentOS Stream | dnf | pkgs.k8s.io | Docker repository | isv:cri-o |
| RHEL, Rocky Linux, AlmaLinux, Oracle Linux | dnf | pkgs.k8s.io | Docker repository (`rhel`) | isv:cri-o |
| openSUSE Tumbleweed, SLES | zypper | pkgs.k8s.io | distribution package | isv:cri-o |
| openSUSE Leap | zypper | pkgs.k8s.io | `Virtualization:containers` | isv:cri-o |
| Alpine Linux | apk | distribution package | distribution package | distribution package |
| Arch Linux, Manjaro | pacman | distribution package | distribution package | distribution package |
| Other (`--distro generic`) | — | release binaries | release binaries | release tarball |

On Alpine and Arch the Kubernetes version is the one the distribution ships; it is the default when `--kubernetes-version` is not given.

## Status legend

- Tested: fully tested and working.
- Failed: not working or major issues.
- Untested: not yet tested.

## Notes

## cgroups v1

Kubernetes 1.35 deprecated cgroups v1: kubelet does not start on a cgroups v1
node by default. On such nodes (Rocky Linux 8, AlmaLinux 8), setup-k8s sets
`failCgroupV1: false` for kubelet (a kubeadm patch for this node, applied on
`init`, `join`, and `upgrade`) and warns. A later Kubernetes release removes
cgroups v1 support; migrate the nodes to cgroups v2 or to a newer release of
the distribution before then.

A distribution is listed while the distribution itself supports the release
(for Rocky Linux 8 and AlmaLinux 8, maintenance support until 2029).

## CRI-O and SELinux

With SELinux enabled, CRI-O installs add the policy module `setup-k8s-crio-bpf`.
It contains one rule: systemd may attach the eBPF device filters that crun
creates for each container. Without it, openSUSE Leap 16 denies them and no
container starts (`systemd failed to install eBPF device filter`). `cleanup`
removes the module. The SELinux mode is not changed.

