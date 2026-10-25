# Embedded-etcd one- or three-server transition plan

Status: implementation in progress. The signed topology contract, staged
one- or three-server K3s flow, direct API health gate, and fail-closed legacy
lifecycle guards are implemented across the three repositories. The remaining
sections are the qualification and follow-on work required before making a
production availability claim. This document supersedes the topology direction
in this repository's architecture and operator guides only when the acceptance
gates below pass.

## Product contract and scope

The supported deployment shapes are **exactly one or three schedulable K3s server
nodes**, each running the pinned K3s binary and participating in embedded etcd.
There are no K3s agents, dedicated worker nodes, external Kubernetes datastore,
or one-server-plus-two-agent production mode. All three servers are active
control-plane and etcd members and may run application workloads. Bootstrap
necessarily passes through one- and two-member transient states; neither is a
completed, healthy installation. With one failed server, the other two retain
etcd quorum. A second failure is a recovery event, not a supported healthy
operating state. Six-node/RF R6 designs require a separate decision.

One signed, architecture-specific, target-portable air-gap release is copied
to every node. The installed cluster has one appliance identity, profile,
version, trust root, and authoritative inventory. Node names, addresses, TLS
names, storage paths, and join credentials are install-time inputs or
target-generated secrets, never build-time bundle identity. The Kubernetes
API uses only the three direct addresses; no network front end is configured
at this milestone. No public egress, install-time downloads, self-updaters,
or separate packaging implementation paths are introduced.

The first release milestone is **Kubernetes control-plane availability**:
three K3s servers, healthy embedded etcd, safe join/rejoin/replacement, and
three independently reachable API entry points. All three are schedulable and can run an ordinary
test workload. Existing product capabilities still run, but today's
singletons and local volumes mean the application can fail when its host fails.
Application availability is a separate milestone with its own storage and
service failover acceptance gate. Status, documentation, and reports must name
these two levels separately.

New releases accept **one or three nodes only**. Old one-server installations
remain readable as migration sources; unsupported two-node and agent layouts
must not erase their data or strand their recovery tools.

## Existing contracts that constrain the work

| Area | Current behavior | Consequence |
| --- | --- | --- |
| K3s | Legacy `zonctl install` uses SQLite by default; `--cluster-init` creates the first etcd server and `cluster-join` can add primes or agents. | An embedded-etcd release must make etcd initialization mandatory and prevent agent/SQLite completion. |
| Cluster state | `single-server`, `server-workers`, and `multi-server` receipts; enrollment changes topology before a peer joins. | State must describe observed members and a desired three-server topology separately. |
| Lifecycle | The first `controlPlaneNode` owns install, backup, upgrade, restore, removal, ingress, and chart placement. | Move cluster operations to a fenced coordinator while keeping one writer for Helm and other shared mutations. |
| Upgrade | The legacy upgrade takes a local K3s directory backup and may rewrite K3s config without `cluster-init`, `server`, or token-file. PostgreSQL upgrade is already refused because rollback is incomplete. | No three-server upgrade can be enabled until a cluster-wide snapshot, rolling order, config preservation, and application recovery are proven. |
| Backup | Legacy backup stops one local K3s service and copies its directory. PostgreSQL recovery sets contain the DB dump and blob archive, but no etcd snapshot/token. | Neither path alone is a complete three-server recovery set. |
| Workloads | Product charts render singleton control-plane, PostgreSQL, blob storage, registry, DNS, UI, workflows, and inference with local/RWO volumes or host paths. | Three-server K3s does not imply application failover. Preserve placement temporarily; redesign each stateful interface before removing it. |
| Release runner | A one- or three-server target inventory derives an install-time inventory, stages the bootstrap and, when present, two peers with signed server enrollments, then finalizes from the bootstrap. It records Kubernetes/etcd health separately from product HTTPS HA. The product release runner rejects legacy target shapes. | Qualify the new runner on LAN and VPS hosts. Legacy receipts remain readable for diagnostics and a future explicit migration workflow; they are not an alternate release-runner path. |

The source surfaces are `appliance-ctl/internal/k3s`, `internal/install`,
`internal/upgrade`, `internal/backup`, `internal/recoveryset`, `internal/state`,
`internal/productconfig`, and `cmd/zonctl`; `appliance-code/deploy/charts`,
its database, object, workflow, inference, and host-agent code; and this
repository's `scripts/install-release.sh`, release skill, manifests, examples,
and verification scripts. Audit the actual tracked files before each slice;
older ADRs and the operator guide currently disagree with newer PostgreSQL
and fresh-reinstall behavior.

## Decisions to freeze before coding

1. **Direct API endpoints.** The Kubernetes milestone uses exactly the three
   server IPv4 addresses, each exposing TLS-authenticated port 6443. A client
   that requires N-1 availability retries the next configured address; no
   floating IP, virtual IP, or mandatory load balancer is introduced. K3s
   certificates include all three addresses and joining peers first use the
   bootstrap address. Qualify this retry behaviour on LAN and hosted VPS
   networks, restrict peer ports, and never rely on a public certificate
   service at runtime. A highly available product HTTPS address remains an
   application-HCH decision, not an implied property of Kubernetes HA. An
   optional host management AP remains local and must not be advertised as
   cluster-wide HA.
2. **Legacy migration.** Choose and test either (a) supported offline export,
   reinstall as three servers, and import, or (b) in-place SQLite-to-etcd
   conversion followed by two server joins. The upstream conversion is
   technically possible, but product data, local PVs, keys, and rollback make
   it a separate qualification project. Until one path passes a restore drill,
   new releases reject in-place topology conversion with an actionable message.
   Provide a complete, tested legacy export path before the support cutover;
   today's PostgreSQL recovery set alone omits K3s state and is insufficient.
3. **Application storage.** Decide the qualified HA provider for PostgreSQL,
   blob/registry objects, workspaces, metadata, model files, video projection,
   and durable logs. Record persistence, ownership, backup, failure, and
   migration semantics for each. Do not treat an RWO PVC or hostPath as
   replicated merely because its pod can be rescheduled. A hosted VPS must
   use the same application contract as an on-premise three-node install.
4. **Availability claims.** Define the Kubernetes-only milestone and the
   later application milestone with measurable failure behavior. Preserve all
   enabled profiles in the first milestone, while explicitly reporting which
   functions require the anchored application node. Do not publish an
   appliance-wide HA claim before the second milestone passes.

## Implementation slices and gates

### 1. Signed topology and preflight contract

- `appliance-code`: add a versioned deployment topology requirement to the
  immutable product release input/compatibility evidence, independent of
  appliance profile. Keep service/chart/image versions separately pinned.
- `appliance-ctl`: carry and validate that requirement in release-input and
  release-manifest schemas, assembly, source resolution, and install options.
  Reject unknown topology metadata and incompatible legacy receipts before
  host mutation. Preserve old schema readers for migration/diagnostics;
  version new receipts instead of reinterpreting legacy fields.
- `appliance-release`: pass the exact signed topology field from product input
  into the final bundle; validate pairing in release artifact tests. Do not
  stamp host IPs, TLS names, or selected front-end implementation into the
  bundle. Keep online/offline packaging using the same path. New dependencies,
  if selected later, need pinned online export, LAN seed, and offline remap.
- Preflight every host for the signed OS/architecture, capacity and fast
  durable etcd storage, time sync, unique node identity, addresses, DNS/TLS,
  inter-server connectivity, and a consistent cluster/service CIDR. Check
  K3s API 6443, etcd 2379/2380, CNI and kubelet/metrics ports only on the
  relevant interfaces; guard against exposure of peer/CNI ports to the public
  internet. Verify each direct API address from the other servers and from
  representative clients; callers retry the other direct address on failure.

Gate: negative fixtures reject two hosts, agents, duplicate names,
mixed releases/architectures, foreign clusters, insufficient resources,
unreachable peers, and an unverified bundle before changing any host.

### 2. One- or three-server bootstrap and membership in `appliance-ctl`

- Replace `--cluster-init` as a user topology choice with the topology in the
  verified release and an explicit one- or three-node install inventory. The first
  server writes `cluster-init`; for a three-server inventory, the other two use `k3s server` with verified
  endpoint, protected server token file, CA pin, and matching critical K3s
  flags. All three receive the same pinned binary and preload set. Never put
  join credentials in arguments, logs, receipts, or support bundles.
- Preserve the protected enrollment artifact/signature mechanism, narrowed to
  server joins and replacement. Record intent before join, then commit a
  member to observed inventory only after matching Kubernetes node UID,
  server/etcd role, version, and Ready state. A failed or expired join is
  rerunnable without inventing a member. Reject a fourth voting server.
- Install product charts exactly once after the planned members and required
  quorum are verified. Use an appliance lifecycle lock/lease and a designated current
  operation coordinator; the first bootstrap host is not a permanent leader.
  Local node agents can stage binaries/images independently, but shared Helm,
  DNS, secrets, and state mutations have one fenced writer.
- Model healthy three-of-three, degraded two-of-three, no-quorum, joining,
  replacing, upgrading, and restoring states. A lost server may be repaired
  or replaced within its slot; replacement must protect against a returning
  stale member and verify etcd membership changes before reuse. Unsafe
  automatic removal or reset is forbidden. Existing foreign K3s adoption
  needs topology/ownership proof; `--force-adopt` must not bypass quorum,
  datastore, or data-preservation checks.
- Keep server configuration stable across restart, repair, and upgrade. Never
  rewrite a joining server as an unjoined server. The presence of etcd files
  alone is not proof that a node is correctly enrolled.

Gate: fake-host and VM tests cover a one-server install, initial 1→2→3
bootstrap, interrupted joins at each mutation point, rerun, reboot, one failed
member, recovered member, replacement, stale member rejection, and foreign
cluster refusal. Completion requires every configured server to be Ready and
to appear as an observed etcd member.

### 3. Network and workload baseline

- Configure the three direct API endpoints in kubeconfig, enrollment,
  control-plane clients, installer reports, and TLS SANs. Clients requiring
  uninterrupted access must retry another configured address; test API traffic
  when each server is removed in turn. For the interim singleton application,
  report its anchored-owner outage accurately; continuous product HTTPS
  responses after a node loss belong to the application HCH gate.
- For the Kubernetes-only milestone, keep local application PVs, host paths,
  and singleton charts on their current owner with explicit placement. This
  preserves current feature behavior while making the temporary limitation
  observable. Do not indiscriminately remove `placement.nodeName` or increase
  replica counts. Keep data under `/data/zon`, UID/GID and storage modes,
  workspace survival, log inspection, profile capabilities, and offline image
  resolution unchanged until each component has a tested replacement.
- Refactor `appliance-code` chart values so topology-wide scheduling and
  component-specific placement are separate. When a component becomes safe
  to move or replicate, add anti-affinity/spread, readiness and disruption
  policy, and validate Restricted PSA and its documented exceptions. Preserve
  each capability's API/route, authentication, RBAC, catalog, DNS, workflow,
  inference, and artifact contracts during the transition.

Gate: every currently supported appliance profile installs and passes its
existing functional checks on the three-node cluster with public egress
denied. Each server runs a scheduled probe workload, and the API remains
available after any one server fails. The report says `Kubernetes HA: pass`
only after that evidence and `Application HA: pending` while any required
stateful function is anchored.

### 4. Cluster-safe lifecycle and recovery

- Replace local K3s-directory copying with K3s embedded-etcd snapshots and
  a protected server token in a verified cluster recovery set. Include the
  installed release/profile, member and endpoint map, app database dump,
  blob/registry state, keys, metadata, and each relevant durable volume by
  explicit policy. Keep workspace-preservation and model-storage policies
  visible. A PostgreSQL recovery set without etcd state cannot claim full
  cluster recovery.
- Back up from one eligible healthy server without stopping an arbitrary
  peer. Verify snapshot/checksums and perform a clean three-host restore
  drill, including token reuse, stale member data disposal, new node UIDs,
  old endpoint replacement, application data, and credentials. Separate
  single-node legacy restores from new cluster restores by format/version.
- Upgrade one server at a time while maintaining quorum: validate all three
  node receipts and images, take a complete recovery set, cordon/drain,
  replace pinned K3s and restore its original join configuration, wait for
  etcd/API/Node Ready, then proceed. Coordinate Helm and stateful migrations
  after the substrate gate. Recovery from a failed step uses a tested
  cluster-wide rollback/restore, not one node's copied data directory.
- Update backup, restore, upgrade, rollback, repair, uninstall, factory reset,
  support bundle, and diagnostics together. Uninstall and factory reset must
  require explicit cluster/member scope and never wipe shared or other-node
  data as an incidental local operation. Preserve `/data/zon/workspaces`
  unless the explicit workspace-wipe option is invoked.

Gate: N-1→N upgrade and rollback, backup under a single server outage, full
restore onto new VPS/LAN hosts, corrupted snapshot/token rejection, interrupted
upgrade/restore, and node replacement all pass. Until then, unsupported
cluster lifecycle commands fail closed with recovery instructions.

### 5. Application HCH milestone in `appliance-code` and `appliance-ctl`

- Move each authoritative state domain to its qualified HA storage/provider
  and migrate data with checksums and a reversible cutover. PostgreSQL needs
  a documented leader/failover and fencing policy; blob storage and the
  artifact registry need durable object consistency; workspaces, metadata,
  video projection, inference models, and operator-visible service logs need
  explicit node failure behavior. Local-only caches may remain local when
  rebuildability is proven. No new runtime dependency may require public
  internet access.
- Replicate only services whose sessions, scheduling, and writes are safe
  across replicas. Establish leader election or idempotent reconciliation for
  control-plane jobs, workflows, DNS publication, maintenance, and inference
  routing. Add placement spread, PDBs, probes, and capacity constraints after
  persistence and concurrency tests pass. Keep stable external API, UI,
  registry, build, file, inference, and backup behavior.
- Add signed release inputs, charts, images, host packages, pins, seeds, and
  offline remaps for any selected HA component through the normal
  `appliance-code` → `appliance-release` → `appliance-ctl` chain. Never
  modify unrelated frozen inputs merely to make this migration build.

Gate: with any one node powered off, the published product endpoint serves
login, API/UI, registry pull/push, files, DNS, workflow submission and result,
and enabled inference within measured recovery targets; data remains correct
after the node returns. Test all profiles, backup/restore, upgrades, and
failure during an active write. Only then publish an application HCH claim.

### 6. Remove obsolete product branches

Once the embedded-etcd path, migration tooling, and lifecycle gates pass:

- Remove agent-mode `zonctl` join and worker upgrade, worker/inference role
  enrollment and registration, `server-workers` creation, one-host public
  install, and release runner `prime,member` cases. Replace worker-targeted
  inference placement with placement on qualified server nodes; preserve
  inference functionality and model data migration. Retain read-only legacy
  receipt parsing, backup/export, and clear migration diagnostics for the
  published support window.
- Remove first-prime-only ingress/ServiceLB labels and cluster-operation
  assumptions after direct API endpoint retry and a coordinator are proven. Retire
  obsolete local PVs/host paths only after their data is migrated and the
  replacement passes the storage, recovery, and security gates.
- Supersede the single-node ADRs and update `AGENTS.md`, product docs,
  schemas, examples, operator guide, release skill config/scripts, component
  catalog, and support matrix. Separate historical plans from current
  instructions so operators do not follow a stale single-node runbook.

Gate: repository searches and schema/CLI tests show only the supported
one- or three-server embedded-etcd write path; old receipts can still be
inspected and exported.

## Functionality preservation review

The node topology cutover does not remove an appliance profile or capability.
For each currently supported profile, compare behavior before and after the
cutover using the same signed product input, client tests, and offline policy.

| Product behavior | Interim embedded-etcd requirement | Application HCH completion check |
| --- | --- | --- |
| Bootstrap, identity, auth, RBAC, licensing, API, MCP, and UI | One chart application and unchanged public contracts; keys and session state survive a controlled restart. | Any one node can fail without losing sign-in or authorized API/UI access; no split-brain writers. |
| Files, blob storage, artifact registry, and OCI clients | Preserve object bytes, digests, credentials, routes, and pull/push behavior on the anchored owner. | A failed node cannot lose a committed object or publish a partial artifact; registry clients reconnect through the stable origin. |
| Builder workspaces, catalogs, and workflows | Keep `/data/zon/workspaces`, ownership, image digests, Git allowlists, workflow history, and build outputs unchanged. | Builds on surviving nodes use the same source trees and reconcile an interrupted task exactly once. |
| LAN DNS, mDNS, management AP, and TLS | Keep zone and certificate identity; report host-local mDNS/AP honestly on LAN and disable unsupported host-network assumptions on VPS. | DNS/HTTPS ingress remains correct after any server loss; host-local controls retain explicit node ownership. |
| Inference, model files, GPU runtime, and WebUI | Preserve enabled inference profiles, model identity, GPU capability checks, routing, and downloaded model bytes while removing agent-only scheduling later. | Model serving/routing recovers after a failed serving node under its declared replication or reload policy. |
| Video, automation, app management, and message broker | Preserve their existing API, storage, and security contracts; inventory their local paths and singletons before moving them. | Each enabled capability meets its declared one-node-loss and recovery behavior. |
| Host agent, diagnostics, logs, and support reports | Preserve host-context execution, numeric UID/GID, readable service logs, and per-node evidence; never turn the pod into a container-local host inspector. | Reports distinguish a failed node from a failed application and retain complete redacted diagnostics. |
| Backup, restore, upgrade, repair, uninstall, reset | Retain safe legacy export/inspection; reject unsupported cluster mutation before changes. | A full cluster recovery set and rolling lifecycle operations pass failure and migration drills. |

The profile regression suite must also check negative capability behavior:
disabled routes, services, images, and secrets remain absent. No new topology
branch may weaken authentication, image verification, Pod Security Admission,
storage ownership, or public-egress denial to make a three-node test pass.

## Cross-repository acceptance matrix

| Change | Producer → consumer check | Evidence |
| --- | --- | --- |
| Topology metadata | `appliance-code` release input → `appliance-ctl` schema/assembly/source → signed bundle → installer | Tamper/unknown/legacy fixtures and digest-pair validation. |
| K3s assets | `appliance-release` online/offline export → manifest → all three local preloads/configs | Same pinned version/digest on every server, no public pulls. |
| API identity and retry | Install inventory → K3s SAN/API list → client and workload callers | A caller retries another direct API address after one server loss; application origin HA remains pending. |
| Placement and storage | `zonctl` values → product charts → PVC/host paths → pod UID/GID and data | Render, writeability, node-loss, migration, restore checks. |
| Product images | OCI annotation and digest reference → preload/tag → Helm values → workloads | Preserve existing `:bundled` annotation and `@sha256` runtime contract. |
| Lifecycle | Cluster receipt/lease → backup/snapshot → rolling upgrade → recovery | Quorum and application data are recoverable after interruption. |

For every edited repository run its `make verify`, then run cross-repo
contract tests with one matched local release input and bundle. Review the
diff by repository and list changed artifacts before requesting a release
run. Real build, publish, and target hosts remain read-only during code
development; the operator runs the documented three-host trial after local
gates pass. No lab reinstall result substitutes for a migration or recovery
test. Keep existing profile and API tests as regression gates; intentional
support removal is limited to node topology modes and their dependent CLI
surface.

## Immediate implementation order

1. Record endpoint, migration, and storage decisions; supersede the topology
   ADR without editing runtime code.
2. Add signed topology metadata and negative preflight/schema tests across
   the three repositories.
3. Implement one- or three-server K3s bootstrap/join plus truthful status and
   Kubernetes-only verification; keep application placement stable.
4. Implement cluster-safe recovery, rolling upgrade, repair, and replacement.
5. Prove all current profiles on one and three servers offline; then retire
   agent and legacy single-host install branches.
6. Implement and qualify application storage/replication and one-node-loss
   operation; then declare application HCH.

K3s reference behavior: [embedded-etcd HA](https://docs.k3s.io/datastore/ha-embedded),
[cluster load balancing](https://docs.k3s.io/datastore/cluster-loadbalancer),
[network requirements](https://docs.k3s.io/installation/requirements),
[etcd snapshots and restore](https://docs.k3s.io/cli/etcd-snapshot), and
[manual rolling upgrades](https://docs.k3s.io/upgrades/manual).
