# Supported Distros

Latest full validation: 2026-06-09 with Kubernetes v1.36.1.

| Distribution | Version | Test Date | Status | Notes |
|---|---|---|---|---|
| Ubuntu | 24.04 LTS | 2026-06-09 | Tested | |
| Ubuntu | 22.04 LTS | 2026-06-09 | Tested | |
| Debian | 13 (Trixie) | 2026-06-09 | Tested | |
| Debian | 12 (Bookworm) | 2026-06-09 | Tested | |
| Debian | 11 (Bullseye) | 2026-06-09 | Tested | |
| RHEL | 9 | - | Untested | Subscription required |
| RHEL | 8 | - | Untested | Subscription required |
| CentOS Stream | 10 | 2026-06-09 | Tested | |
| CentOS Stream | 9 | 2026-06-09 | Tested | |
| Rocky Linux | 10 | 2026-06-09 | Tested | |
| Rocky Linux | 9 | 2026-06-09 | Tested | |
| Rocky Linux | 8 | 2026-06-09 | Partial | cgroups v1 only; use Kubernetes 1.33 or earlier |
| AlmaLinux | 10 | 2026-06-09 | Tested | |
| AlmaLinux | 9 | 2026-06-09 | Tested | |
| AlmaLinux | 8 | 2026-06-09 | Partial | cgroups v1 only; use Kubernetes 1.33 or earlier |
| Oracle Linux | 9 | 2026-06-09 | Tested | |
| Fedora | 44 | 2026-06-09 | Tested | |
| Fedora | 43 | 2026-06-09 | Tested | |
| openSUSE | Tumbleweed | 2026-06-09 | Tested | |
| openSUSE | Leap 16.0 | 2026-06-09 | Tested | |
| SLES | 15 SP5 | - | Untested | Subscription required |
| Alpine Linux | 3.23 | 2026-06-09 | Tested | OpenRC, cgroupfs |
| Arch Linux | Rolling | 2026-06-09 | Tested | |
| Manjaro | Rolling | - | Untested | No cloud image |

## Status legend

- Tested: fully tested and working.
- Partial: works with some limitations or manual steps.
- Failed: not working or major issues.
- Untested: not yet tested.

## Notes

Kubernetes 1.34+ requires cgroups v2 because cgroups v1 support was removed. Use `--kubernetes-version 1.33` or earlier on distributions limited to cgroups v1.
