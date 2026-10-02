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

## Defaults Used Below

Distributor base URL, version stamp, state dir, and other paths are product
defaults inside the published helper (or stamped at publish). Operators pass
only appliance identity on the CLI.

```bash
# Open static HTTP example (adjust host/version for curl step only):
RELEASE_BASE_URL=http://192.168.1.103:28081
RELEASE_VERSION=0.1.0
```

## Normal Public Flow: Install Or Upgrade

Two steps. Version is chosen by the **download URL**. The run takes only a
required appliance name and an optional profile (default `core`). It does not
read operator env vars for the public path.

### 1) Get the install script

Open static publish:

```bash
curl -fsSL -o install-release.sh \
  "${RELEASE_BASE_URL}/appliance/${RELEASE_VERSION}/install-release.sh"
```

Authenticated appliance_files store (token only for this download curl):

```bash
curl -fsSL -o install-release.sh \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "https://artifact.example.internal/api/v1/files/appliance/${RELEASE_VERSION}/install-release.sh"
```

### 2) Run with a stable appliance name

`--appliance-name` is required and should stay stable for that device (FQDN,
TLS, registry realm). Omit profile to install the base `core` profile.

```bash
bash install-release.sh --appliance-name my-appliance-1

bash install-release.sh \
  --appliance-name my-appliance-1 \
  --appliance-profile storage-landns
```

Installation does **not** require a license file and does not perform online
entitlement checks. By default, after first UI login, complete licensing setup
(import an offline license or accept the base/free entitlement) from Admin /
Licensing.

Rare site overrides (authenticated private store TLS, builder catalog path,
alternate state dir) live as editable product-default variables near the top
of the downloaded script — not as public CLI flags.

Valid v1 profiles:

- `core`
- `builder`
- `storage`
- `landns`
- `storage-landns`
- `builder-landns`
- `builder-storage-landns`

Profile selection does not change the published bundle files or create a
different SKU.

## What The Wrapped Flow Does

- downloads `appliance-<version>-foundation.tar.gz`
- downloads `release-signing.pub`
- verifies `sha256sum.txt`
- extracts the bundle under `/tmp/appliance-<version>`
- runs `zonctl preflight`
- runs `zonctl install` on a fresh host
- automatically switches to `zonctl upgrade` when the target already has an
  owned appliance install
- does not create the first administrator or accept a license (do those in the
  UI, or via release-flow config `install.bootstrap_admin` /
  `install.enable_default_license`)
- installs `zonctl` to `/usr/local/bin/zonctl`

## Explicit Manual Install / Upgrade

Use this only when you want the steps spelled out manually instead of
using the wrapped helper above.

```bash
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

curl -fLo "${WORK_DIR}/appliance-${RELEASE_VERSION}-foundation.tar.gz" \
  "${RELEASE_BASE_URL}/appliance/${RELEASE_VERSION}/appliance-${RELEASE_VERSION}-foundation.tar.gz"
curl -fLo "${WORK_DIR}/release-signing.pub" \
  "${RELEASE_BASE_URL}/appliance/${RELEASE_VERSION}/release-signing.pub"
curl -fLo "${WORK_DIR}/sha256sum.txt" \
  "${RELEASE_BASE_URL}/appliance/${RELEASE_VERSION}/sha256sum.txt"

( cd "${WORK_DIR}" && sha256sum -c sha256sum.txt )
tar -C "${WORK_DIR}" -xzf "${WORK_DIR}/appliance-${RELEASE_VERSION}-foundation.tar.gz"
chmod +x "${WORK_DIR}/appliance-${RELEASE_VERSION}-foundation/zonctl"
```

Fresh install:

```bash
sudo "${WORK_DIR}/appliance-${RELEASE_VERSION}-foundation/zonctl" preflight --output text
sudo "${WORK_DIR}/appliance-${RELEASE_VERSION}-foundation/zonctl" install \
  --bundle-dir "${WORK_DIR}/appliance-${RELEASE_VERSION}-foundation" \
  --public-key "${WORK_DIR}/release-signing.pub" \
  --state-dir "${STATE_DIR}" \
  --output text
```

Upgrade:

```bash
sudo "${WORK_DIR}/appliance-${RELEASE_VERSION}-foundation/zonctl" preflight --output text
sudo "${WORK_DIR}/appliance-${RELEASE_VERSION}-foundation/zonctl" upgrade \
  --bundle-dir "${WORK_DIR}/appliance-${RELEASE_VERSION}-foundation" \
  --public-key "${WORK_DIR}/release-signing.pub" \
  --state-dir "${STATE_DIR}" \
  --output text
```

## What `zonctl install` Actually Does

1. Verifies the release manifest and every bundle artifact.
2. Runs preflight on the real host.
3. Makes the K3s ownership decision.
4. Installs or adopts K3s as allowed by policy.
5. Preloads verified K3s and application images.
6. Applies the exact bundled Helm chart.
7. Persists `installed-state.json` on success.

The install path is bundle-only in v1. There is no remote fallback and no
unverified substitution. First-admin creation and base license acceptance are
not part of `zonctl install`; use the control-plane UI or the release-flow
config keys `install.bootstrap_admin` and `install.enable_default_license`.

## Appliance roles: prime and member

The operator config names hosts as **prime** or **member**. Do not put
Kubernetes terms in that YAML.

- **prime** owns the appliance identity. Product HTTPS and
  `<appliance-name>.local` always resolve to this host’s LAN IPv4. Charts,
  host-agent, Traefik, LAN DNS, and `/data/zon` hostPath stay here.
- **member** joins the same appliance name and signed bundle. It does not
  advertise `.local` and does not install product charts.

One alias with no `roles:` key is a single-host appliance (implicit prime).
Two hosts are always `prime,member`. Cluster HA needs three primes; two
primes are rejected.

## Explicit extra-host enrollment

The first listed prime is the advertised LAN owner and the only mDNS/ingress
host. Add a member only with the same verified release bundle; never discover
peers through mDNS or install a member from the internet.

On the advertised prime, create an owner-readable enrollment artifact for the
specific member node name and its reachable API endpoint. Transfer this file by
an operator-approved protected offline channel. Members receive an automatically
expiring **join token** (15 minutes by default, configurable from one minute
through 24 hours). Extra primes (three-prime HA only) receive the server join
credential in the same enrollment envelope; it is never printed. Do not paste
enrollments into terminals, tickets, or logs; create a fresh enrollment if it
expires before the host joins.

```bash
sudo zonctl cluster-enrollment-create \
  --worker-name gpu-worker-1 --worker-role inference \
  --control-endpoint https://10.0.0.10:6443 \
  --enrollment-out /root/gpu-worker-1.enrollment
```

For a compute member, use `--worker-role worker`. For an extra prime in a
three-prime cluster, use `--worker-role prime` (fresh install only; do not
migrate a one-prime SQLite appliance in place).

Record the reported signer fingerprint through a separate trusted channel. On
the joining host, use its local copy of the signed bundle and that pinned fingerprint:

```bash
sudo zonctl cluster-join \
  --bundle-dir /media/zon/foundation \
  --enrollment-file /root/gpu-worker-1.enrollment \
  --cluster-signer-fingerprint sha256:<fingerprint> \
  --node-name gpu-worker-1
```

After K3s reports the node ready, return to the control plane to verify, label,
and add it to authoritative inventory:

```bash
sudo zonctl cluster-node-register --worker-name gpu-worker-1 --worker-role inference
```

For an accelerated (`acc-llm` / vLLM) worker, `cluster-join` configures the
NVIDIA container runtime on that worker after its K3s agent starts. The later
control-plane deployment step creates the shared Kubernetes `RuntimeClass`.
Do not try to copy containerd configuration from the control-plane host; GPU
runtime configuration is per node.

After registration, reconcile that node's isolated inference release from the
same signed bundle selection. This creates a node-bound manager, engine
service, and model claim; it never accepts image, selector, or endpoint input
from the command line. The control plane records the Kubernetes node UID at
registration and uses that UID—not the reusable node name—as durable model
instance identity.

```bash
sudo zonctl cluster-inference-deploy \
  --bundle-dir /media/zon/foundation \
  --pack-dir /media/zon/std-llm \
  --worker-name gpu-worker-1
```

To remove a worker, run this on the control plane. It cordons the node,
atomically removes that node's ready-model aliases from the shared inference
routing registry, drains Kubernetes work, removes that node's isolated Helm
release, then deletes the node and inventory record. If a concurrent model
publication changes the registry, the operation fails closed; rerun it rather
than risking loss of another node's route:

```bash
sudo zonctl cluster-node-remove --worker-name gpu-worker-1 --confirm gpu-worker-1
```

### Ordered cluster upgrade

An appliance upgrade is ordered: copy the same signed target bundle to each
worker, upgrade each worker locally, confirm its Kubernetes node is Ready, and
only then upgrade the control plane. No host is remotely modified and the
control plane refuses its own upgrade while any enrolled worker reports a K3s
version other than the signed target.

```bash
# Run on each worker first, using that worker's local bundle copy.
sudo zonctl cluster-worker-upgrade \
  --bundle-dir /media/zon/foundation \
  --pack-dir /media/zon/std-llm \
  --node-name gpu-worker-1

# Then run on the control plane. It checks every enrolled worker live.
sudo zonctl upgrade --bundle-dir /media/zon/foundation --pack-dir /media/zon/std-llm
```

If a worker update fails after replacing its K3s files, `zonctl` restores the
prior binary, agent configuration, and unit before restarting the agent.

## What `zonctl upgrade` Actually Does

1. Loads current installed state.
2. Resolves and verifies the target bundle.
3. Checks upgrade compatibility and refuses unsupported jumps.
4. Takes and verifies a mandatory pre-upgrade backup.
5. Stages new images.
6. Swaps the K3s binary only if the pinned K3s version changed.
7. Applies the new chart.
8. Persists updated installed state.

Any failure after mutation starts triggers restore-based rollback.

## Backup And Restore

Backup:

```bash
sudo zonctl backup --state-dir "${STATE_DIR}" --output text
```

Run the same command on every worker. On an inference worker it snapshots the
local K3s agent data and `/data/zon/inference/models` in one checksummed local
backup. That model snapshot is node-local: retain or transfer the complete
backup directory through an operator-approved offline channel; it is never
assumed to be present on the control plane or another worker.

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

- prior operation interrupted:
  run `zonctl repair`
- `requires-force-adopt`:
  see [security-model.md](security-model.md#k3s-ownership)
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

- Fresh host, no Zon installed:
  use the wrapped install-or-upgrade flow
- Zon already installed, newer release:
  use the wrapped install-or-upgrade flow
- Same version, reconcile in place:
  use the wrapped install-or-upgrade flow
- You specifically want the lower-level explicit commands:
  use the manual flow
- Previous operation was interrupted:
  use `repair`
- Remove platform but preserve data:
  use `uninstall`
- Wipe everything and start over:
  use `factory-reset`, then reinstall

## Reboot Guidance

Normal Zon install, upgrade, repair, uninstall, and factory-reset flows do not
require a full host reboot.
