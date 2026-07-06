# Support Matrix

Implementation package names referenced below now live in the
`appliance-ctl` repo, which owns the `zonctl` source tree.

## Qualified Host Baseline (v1)

| Requirement | Value | Enforced by |
| --- | --- | --- |
| Operating system | Ubuntu Server 22.04 LTS or 24.04 LTS | `os-arch-supported` preflight check |
| Architecture | `amd64` | `os-arch-supported` preflight check |
| CPU | 4 cores minimum | `cpu-count-min` preflight check |
| Memory | 8 GiB minimum | `memory-min` preflight check |
| Appliance data filesystem | Local `ext4` | `data-dir-filesystem-ext4` preflight check |
| Appliance data free space | 50 GiB minimum | `data-dir-free-space` preflight check |
| Appliance data free inodes | 200,000 minimum | `data-dir-free-inodes` preflight check |
| cgroups | v2 (unified hierarchy) | `cgroup-v2-enabled` preflight check |
| Kernel user namespaces | Enabled | `kernel-user-namespaces-enabled` preflight check |
| IPv4 forwarding | Enabled (auto-fixed if not) | `ipv4-forwarding-enabled` preflight check |
| Time synchronization | Active (systemd-timesyncd/chrony) | `time-sync-active` preflight check |
| Hostname | Internally resolvable, valid TLS SAN | `internal-dns-resolvable`, `hostname-valid-tls-san` |
| Ports | `6443`, `10250`, `8472` free | `required-ports-available` preflight check |
| Conflicting services | None (`docker`, `microk8s`, unrelated `kubelet`) | `no-conflicting-services` preflight check |
| Existing K3s | Only if installed and owned by this Zon installation | K3s ownership decision (`internal/k3s.DecideOwnership`) |

Run `zonctl preflight --output json` for the authoritative, machine-readable
report against the exact host being installed on — this table summarizes
what that command checks, not a replacement for running it.

A host that fails any check above with `unsupported` or `operator-action`
blocks `zonctl install` outright. `auto-fix` findings (currently only
IPv4 forwarding) are corrected automatically as part of installation.

## Deferred (Not Supported in v1)

Per [release-plan.md](release-plan.md)'s Deferred section: installation
onto pre-existing Kubernetes/K3s clusters, multi-node/HA K3s, additional
Linux distributions or architectures, bootable ISO/VM/hardware image
distribution, automatic release-channel upgrades, connected or thin
installation packages, and package/profile variants of the v1 topology.
Each requires its own qualification evidence before being added here.
