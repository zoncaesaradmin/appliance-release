# Operator Guide

Audience: target device / target host operator only.

This page is the canonical target-host runbook for a published Zon release.
It combines install, upgrade, backup, recovery, verification, troubleshooting,
and host-baseline guidance in one place.

All lifecycle commands below should be run with `sudo`, because the appliance
state directory is `/var/lib/zon/state` and the installer owns K3s on the
host. Builder workspace data is separate and defaults to `/data/zon/workspaces`.

The Control Plane always provisions an `apps` namespace for Application
Management, even when no application is installed. It is separate from
`ace-apps`, which is reserved for co-packaged UI, host-agent, and Automation
Runtime components. Application Management does not modify Automation Runtime.

## Qualified Host Baseline

| Requirement | Value | Enforced by |
| --- | --- | --- |
| Operating system | Ubuntu Server 22.04 LTS or 24.04 LTS | `os-arch-supported` preflight check |
| Architecture | `amd64` | `os-arch-supported` preflight check |
| CPU | 1 core minimum | `cpu-count-min` preflight check |
| Memory | 2 GiB minimum | `memory-min` preflight check |
| Appliance data filesystem | Local `ext4` | `data-dir-filesystem-ext4` preflight check |
| Appliance data free space | 20 GiB minimum | `data-dir-free-space` preflight check |
| Appliance data free inodes | 200,000 minimum | `data-dir-free-inodes` preflight check |
| cgroups | v2 (unified hierarchy) | `cgroup-v2-enabled` preflight check |
| Kernel user namespaces | Enabled | `kernel-user-namespaces-enabled` preflight check |
| IPv4 forwarding | Enabled (auto-fixed if not) | `ipv4-forwarding-enabled` preflight check |
| Time synchronization | Active | `time-sync-active` preflight check |
| Hostname | Internally resolvable, valid TLS SAN | `internal-dns-resolvable`, `hostname-valid-tls-san` |
| Ports | `6443`, `10250`, `8472` free on a fresh host | `required-ports-available` preflight check |
| Conflicting services | None (`docker`, `microk8s`, unrelated `kubelet`) | `no-conflicting-services` preflight check |

Run `zonctl preflight --output json` for the authoritative report against the
exact host being installed on.

## Name-Based Access

Prefer host names over raw appliance IPs for day-to-day access.

- Profiles with the `lan-discovery` capability enable host mDNS at
  installation and advertise `<appliance-name>.local`, for example
  `https://appliance.local` or `ssh <user>@appliance.local`.
- This mDNS name is not a static `/etc/hosts` entry. `manage.ap` is likewise
  absent from the appliance LAN hosts file; it exists only when Wi-Fi AP mode
  serves its private management network.
- When a DNS-bearing profile is in use and its A record has been published,
  use the derived appliance name `<appliance_name>.<dns_zone>`, for example
  `https://appliance.appliance.internal`.

## Production installation

New releases have one supported installation path: the signed release runner
coordinates exactly one or three hosts. Do **not** download a helper and run
`zonctl install` or `zonctl upgrade` on one host; those local-host commands
cannot complete an `embedded-etcd-v1` release and must not be used as a
fallback.

The release runner consumes three operator-owned inputs: a dev-host target
configuration with exactly one or three aliases, build/publish configuration,
and installation identity/profile configuration. It verifies the signed
foundation bundle on each host, then performs the staged server flow described
below. The runner and its exact configuration examples are maintained with the
release tooling in
[`references/script-usage.md`](../.agents/skills/release/references/script-usage.md).

The process remains air-gapped at the target: the bundle, K3s payload, charts,
and images are all verified before use; there is no public fallback or
unverified substitution. First-admin creation and offline-license acceptance
remain post-install control-plane actions and are not part of K3s bootstrap.

The supported profiles remain `core`, `builder`, `storage`, `landns`,
`storage-landns`, `builder-landns`, and `builder-storage-landns`. Profile
selection changes enabled product capability, not the embedded-etcd topology.

## Supported topology: one or three active K3s servers

A new signed release supports exactly one or three servers. Every server runs
`k3s server`, participates in embedded etcd, exposes a Kubernetes API, and is
schedulable for workloads. There are no agent, dedicated worker, or
one-server-plus-two-agent deployment modes.

The operator supplies an install-time inventory containing the one or three host
names and their directly reachable IPv4 addresses. It is copied to each target
with the signed bundle but is not embedded in that portable bundle. There is no
extra reserved VIP or required load balancer. From a laptop, any live server
works:

```bash
curl -k https://192.168.1.155:6443/readyz
curl -k https://192.168.1.153:6443/readyz
curl -k https://192.168.1.152:6443/readyz
```

The certificate contains every direct inventory address. In a three-server
installation, a client needing N-1 availability must retry another address
when a connection fails; a normal single URL in a kubeconfig does not supply
automatic failover. Peers initially join the bootstrap server, then every
direct API address is checked.

The release runner performs the signed, resumable sequence:

1. Stage the bootstrap server using `zonctl cluster-server-stage`.
2. For a three-server inventory, create a protected, short-lived server
   enrollment for each peer. A one-server inventory has no peer enrollment.
   Transfer each only through the release runner or a protected offline channel;
   never paste one into a terminal, ticket, or log.
3. Stage every peer with `cluster-server-stage`. They are K3s servers, never
   agents.
4. Run `zonctl cluster-finalize` on the bootstrap server. It deploys charts
only after every planned server is Ready, schedulable, accepting its
   direct API URLs, and is a voting embedded-etcd member.

Use `zonctl cluster-ha-check` from any running server to repeat the
Kubernetes/etcd checks. A passing result means Kubernetes control-plane HA,
not application HTTPS HA: the current application placement and durable
storage are intentionally qualified in a later milestone.

Legacy prime/member and worker commands remain readable only for supported
migration and recovery of older releases. They are not a deployment option
for a release signed with `embedded-etcd-v1`.

## Upgrade, backup, and recovery

Cluster-wide rolling upgrade, embedded-etcd snapshot/restore, member
replacement, uninstall, and factory reset are not yet qualified for the
embedded-etcd topology. Those mutating legacy commands fail closed on a staged
or finalized appliance so they cannot operate on an etcd member as if it were
an independent appliance. Preserve the complete inventory and use the
documented recovery process until the cluster-wide workflow has passed its
failure drills.

The following describes legacy single-node behavior only; do not use it as an
embedded-etcd operating procedure.

### Legacy `zonctl upgrade` behavior

1. Loads current installed state.
2. Resolves and verifies the target bundle.
3. Checks upgrade compatibility and refuses unsupported jumps.
4. Takes and verifies a mandatory pre-upgrade backup.
5. Stages new images.
6. Swaps the K3s binary only if the pinned K3s version changed.
7. Applies the new chart.
8. Persists updated installed state.

Any failure after mutation starts triggers restore-based rollback.

### Legacy backup and restore

Backup:

```bash
sudo zonctl backup --state-dir "${STATE_DIR}" --output text
```

Restore:

```bash
sudo zonctl restore --backup-id <backup-id> --state-dir "${STATE_DIR}" --output text
```

Behavior:

- backup stops K3s, copies the K3s data directory into
  `<state-dir>/backups/<backup-id>/data`, writes a manifest, and restarts K3s
- restore verifies the backup first, then stops K3s, replaces the data
  directory, and restarts K3s

`zonctl upgrade` takes and verifies a backup automatically before changing
anything.

## Recovery And Day-2 Operations

Repair a failed or interrupted operation:

```bash
sudo zonctl repair --state-dir "${STATE_DIR}" --output text
```

Uninstall while preserving platform data:

```bash
sudo zonctl uninstall \
  --state-dir "${STATE_DIR}" \
  --confirm <token> \
  --output text
```

Factory reset:

```bash
sudo zonctl factory-reset \
  --state-dir "${STATE_DIR}" \
  --confirm <token> \
  --acknowledge-data-loss \
  --backup-id <backup-id> \
  --output text
```

Add `--force-data-loss` when intentionally proceeding without a verified
backup, and add `--wipe-workspaces` when builder workspace source trees under
`/data/zon/workspaces` must also be removed.

## Verification

Independent bundle verification before install:

1. Verify `release-manifest.sig` against `release-signing.pub`
2. Verify every bundle artifact digest against `release-manifest.json`
3. Confirm install still succeeds with public egress blocked

The install and upgrade commands already perform those checks automatically.

Installed host verification:

- `zonctl status` reports installed version and K3s health
- `zonctl verify` checks installed-state integrity and current K3s health

Current limitation: `zonctl verify` does not yet re-verify every installed
artifact against the original release manifest after install time.

Support bundle verification:

```bash
sha256sum <bundle-path>
```

Compare against `data.digest` from `zonctl support-bundle`.

## Troubleshooting

Runtime service logs live under:

```text
/data/zon/logs
```

Common service log directories:

```text
/data/zon/logs/api-server/
/data/zon/logs/ui/
/data/zon/logs/workflow-controller/
/data/zon/logs/artifactserver/
/data/zon/logs/dns/
```

Kubernetes-native access remains important:

```bash
sudo kubectl -n ace-system logs deploy/controlplane
sudo kubectl -n ace-system logs deploy/ui-server
sudo kubectl -n workflows logs deploy/workflow-controller
sudo kubectl -n appliance-builds logs <pod-name>
sudo journalctl -u k3s -f
```

Common cases:

- interrupted three-server stage or finalization:
  rerun the same signed release-runner flow after inspecting `zonctl status
  --output json` on the affected server; do not run local `repair`
- `requires-force-adopt`:
  this is not a supported path for a new three-server release; preserve the
  existing cluster for the explicit migration/recovery workflow
- unhealthy status:
  inspect `zonctl status --output json` and component logs

## Capability Notes

Artifact registry usage from another machine:
see [artifact-registry.md](artifact-registry.md).

LAN DNS setup and record management:
see [lan-dns.md](lan-dns.md).

Notes for DNS-bearing profiles:

- `landns`, `storage-landns`, `builder-landns`, and `builder-storage-landns`
  install the appliance-owned CoreDNS release
- the local zone is `appliance.internal` by default, or `install.dns_zone`
  when set
- install does not seed or publish product A records
- add names later through the DNS API/UI or peer publish API

## When To Use Which Path

- Three fresh, inventory-matched hosts:
  use the signed three-server release runner.
- A staged three-server flow was interrupted:
  preserve all three hosts and rerun that same release-runner flow; it resumes
  only against matching signed inventory and stage receipts.
- A finalized three-server appliance needs diagnosis:
  use `cluster-ha-check`, `status`, `verify`, and `support-bundle`. Its
  cluster-wide upgrade, restore, replacement, uninstall, and reset workflow
  is deliberately not yet qualified; local lifecycle commands fail closed.
- An older one-server/prime-member receipt:
  use the separately documented legacy export/migration or recovery procedure;
  it is not an alternate new-install path.

## Reboot Guidance

Three-server staging and verification do not require a full host reboot.
Do not reboot multiple embedded-etcd servers at once: two available servers
are required to retain quorum. Cluster-wide maintenance guidance will replace
this interim restriction once its recovery and rolling-upgrade drills pass.
