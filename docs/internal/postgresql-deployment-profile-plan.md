# PostgreSQL Control Plane And Deployment Profile Plan

## Purpose

This is the execution plan for moving the production control plane from
SQLite to PostgreSQL without breaking the existing appliance behavior. It
also introduces the **deployment profile** concept needed to vary topology
and resource settings independently from product capabilities.

The first deliverable is deliberately narrow:

- PostgreSQL is the only production control-plane database.
- The only supported deployment profile is `single-node-postgres-v1`.
- That profile runs one control-plane replica and one PostgreSQL primary on
  appliance-owned durable local storage.
- SQLite remains usable only for local development and transition testing;
  it is not an installable production option after this work lands.

This plan does not implement PostgreSQL high availability, arbitrary sizing
knobs, or a broad menu of install-time profiles. It creates the stable
contracts that let those be added later without a packaging redesign.

## Non-Goals For This Delivery

- Three-node or replicated PostgreSQL.
- Automatic PostgreSQL failover.
- Multiple supported capacity tiers or operator-entered CPU/memory values.
- Cross-cluster cloning as a blind database or K3s-data copy.
- Changing product capability/profile semantics.
- Any connected install, runtime image pull, extension download, or public
  internet dependency.

## Terms And Boundaries

| Term | Meaning | Not the same as |
| --- | --- | --- |
| Product capability profile | Signed product behavior such as artifact, build, DNS, or inference capability | Deployment profile |
| Deployment profile | Signed, versioned topology and operational defaults selected at install time | User-created performance tuning |
| Resolved deployment values | Complete rendered topology/resources/storage/backup values for the selected profile | Mutable Helm defaults |
| Recovery set | Authenticated, encrypted, versioned collection of control-plane state, configuration, keys, infrastructure state, and verification data | A PostgreSQL dump alone |
| Configuration revision | Validated desired appliance configuration with audit history and apply result | Disaster-recovery restore |

The existing product capability/profile model remains capability-oriented.
`single-node-postgres-v1` must not imply that a product capability is enabled
or disabled. Conversely, selecting a build or inference capability must not
silently choose database topology or resource limits.

## Target Architecture

```text
Signed release bundle
  ├─ pinned control-plane, PostgreSQL, chart, and backup inputs
  ├─ signed deployment-profile schema/defaults
  └─ zonctl
       ├─ selects single-node-postgres-v1
       ├─ records resolved profile + values digest in installed state
       ├─ creates secrets and durable storage
       └─ renders verified Helm values

control-plane API pods ── bounded pool/TLS ── PostgreSQL primary
       │                                        │
       ├─ versioned configuration revisions     └─ dedicated RWO PVC
       └─ singleton maintenance guarded by DB/lease

coordinated recovery set
  ├─ PostgreSQL backup + verification metadata
  ├─ resolved deployment configuration
  ├─ K3s etcd snapshot/recovery material
  ├─ keys, certificates, metadata bundles
  └─ artifact/blob data and its consistency evidence
```

The first profile keeps the control-plane API at one replica while the
PostgreSQL adapter and chart are made replica-safe. A later multi-node profile
can then add control-plane replicas without changing API/domain persistence
contracts.

## Initial Deployment Profile Contract

The product release input owns the set of allowed profile identifiers,
schemas, defaults, and compatibility. `zonctl` accepts one allowed identifier,
resolves it to exact values, and records its immutable resolved form.

Initial identifier:

```yaml
id: single-node-postgres-v1
database:
  engine: postgresql
  topology: single-primary
controlPlane:
  replicas: 1
```

The exact CPU, memory, connection-pool, storage, and backup values are
release-owned defaults, not user-facing free-form fields. Start from measured
small bounds; provisional implementation candidates are a PostgreSQL request
of 128 MiB and limit of 256–384 MiB, and a control-plane request of 128–256
MiB and limit of 256–384 MiB. These numbers are not a support claim until the
performance gate below passes.

Each install and recovery set must retain:

- release ID and platform version;
- deployment-profile ID and schema version;
- canonical resolved values document and digest;
- database engine/version and migration level;
- storage class/claim identity and required ownership contract;
- backup format/version and encryption/key-reference metadata.

## Workstreams And Ownership

| Workstream | Primary repository | Required consumers |
| --- | --- | --- |
| Domain stores, PostgreSQL adapter, migrations, migration tool, configuration revisions | `appliance-code` | `appliance-ctl` |
| Control-plane/PostgreSQL chart, resource/profile value schema, security contexts | `appliance-code` | `appliance-ctl`, `appliance-release` |
| Deployment-profile selection, install state, image preload, backup/restore orchestration | `appliance-ctl` | `appliance-code`, `appliance-release` |
| Signed release-input/bundle contract, PostgreSQL dependency seed/remap and validators | `appliance-release` | `appliance-code`, `appliance-ctl` |
| Performance, upgrade, restore, air-gap and end-to-end evidence | all three | all three |

No repository may land a one-sided producer/consumer change. In particular,
the PostgreSQL image/chart, profile schema, profile values, install selection,
backup manifest, and control-plane configuration must move together.

## Ordered Execution Milestones

### M0 — Contract Freeze And Inventory

**Goal:** create an agreed migration boundary before code changes.

Deliverables:

- `appliance-code` ADR replacing the production SQLite decision with the
  PostgreSQL/deployment-profile decision.
- A versioned deployment-profile schema and one fixture for
  `single-node-postgres-v1`.
- A persistence inventory naming every SQLite store, table, direct SQL
  dialect dependency, SQLite-only backup path, and startup assumption.
- A recovery-set contract that distinguishes configuration revision replay
  from disaster recovery.
- A cross-repo release-input compatibility change proposal for the pinned
  PostgreSQL image/chart and profile metadata.

Exit gate:

- profile selection is explicitly separate from product capabilities;
- exactly one initial profile is supported;
- all current SQLite data and every database-adjacent secret are accounted for;
- rollback semantics are accepted: after data migration, rollback restores a
  verified pre-upgrade recovery set rather than merely retagging an image.

### M1 — Storage Construction Seam

**Goal:** remove the remaining production dependency on concrete SQLite
construction without changing behavior.

Implementation in `appliance-code`:

- Introduce a storage backend/provider that constructs `storage.DB` and every
  repository interface as one coherent set.
- Change `internal/app/services.go` to receive that provider rather than
  importing `internal/storage/sqlite` and constructing each store directly.
- Preserve existing domain interfaces, error semantics, transaction behavior,
  HTTP handlers, MCP routes, authentication, workflow services, and tests.
- Keep SQLite as the provider used by current local/development tests.

Exit gate:

- existing SQLite tests remain unchanged in observable behavior;
- no package outside a storage adapter imports driver-specific types;
- a test can wire the complete service set through a fake/provider seam;
- `make verify` passes in `appliance-code`.

### M2 — PostgreSQL Adapter And Schema

**Goal:** implement the production backend behind the existing interfaces.

Implementation in `appliance-code`:

- Add a pinned PostgreSQL driver and a dedicated `storage/postgres` adapter.
- Maintain PostgreSQL-native migration files and migration-history checks;
  do not execute the SQLite migration files against PostgreSQL.
- Map SQL failures consistently to `storage.ErrNotFound`,
  `storage.ErrConflict`, and explicit unavailable/timeout errors.
- Add bounded connection-pool, connection lifetime, query timeout, and
  transaction settings to typed configuration.
- Acquire a database migration/advisory lock so later control-plane replicas
  cannot apply migrations concurrently.
- Ensure readiness verifies usable database connectivity, not only an open
  TCP port.
- Preserve fixed IDs, timestamp precision, audit hash-chain contents, binary
  token/key material, foreign-key behavior, and uniqueness constraints.

Exit gate:

- the complete repository contract suite passes against PostgreSQL;
- migration startup refuses unknown, dirty, partial, and newer schema states;
- concurrent-write, transaction rollback, uniqueness, timeout, and restart
  tests pass;
- no production path opens a SQLite database.

### M3 — Safe SQLite-To-PostgreSQL Upgrade Tool

**Goal:** support already-installed SQLite appliances without data loss.

Implementation in `appliance-code` and `appliance-ctl`:

1. Create and verify a complete pre-upgrade recovery set.
2. Enter installer-controlled maintenance mode; reject new writes and wait for
   in-flight mutations to settle or become explicitly interrupted.
3. Produce a consistent SQLite snapshot using the existing safe path.
4. Create and migrate the target PostgreSQL schema.
5. Import data in foreign-key-safe order in bounded transactions.
6. Verify table counts, key identifiers, role grants, active state,
   credential/token lookup behavior, audit sequences/hashes, and metadata
   activation state.
7. Atomically switch the release configuration to PostgreSQL and start the
   new control plane only after verification succeeds.
8. Retain SQLite source/snapshot until post-upgrade health and smoke checks
   complete; never truncate/recreate it automatically.

Exit gate:

- happy-path migration has automated fixture coverage;
- injected interruption at every checkpoint is recoverable or rerunnable;
- no failed conversion mutates the source SQLite file;
- rollback procedure is documented and tested through recovery-set restore.

### M4 — PostgreSQL Runtime And Helm Delivery

**Goal:** deploy a pinned, secure, air-gapped PostgreSQL primary.

Implementation in `appliance-code`:

- Add PostgreSQL workload/service, dedicated PVC, resource settings, probes,
  security contexts, NetworkPolicy, and database bootstrap/migration path to
  the canonical chart.
- Run PostgreSQL under its own fixed numeric UID/GID with a dedicated data
  path/PVC; do not share the control-plane data volume.
- Keep the control-plane root filesystem read-only and mount only necessary
  writable paths.
- Pass database credentials only through installer-created Kubernetes Secrets;
  do not put them in ConfigMaps, values files, logs, command arguments, or
  support bundles.
- Introduce profile-derived chart values. The chart must reject unsupported
  topology/replica combinations rather than silently accepting them.

Implementation in `appliance-ctl`:

- Resolve `single-node-postgres-v1` during install and upgrade.
- Persist its resolved-values digest in installed state and include it in
  diagnostic/evidence output.
- Verify database PVC binding, ownership, image preload, service readiness,
  schema state, and control-plane readiness before success.

Exit gate:

- fresh installation succeeds with public egress denied;
- Helm render/schema tests reject unsupported profile values;
- image references are pinned and preloaded before Helm;
- storage ownership and writeability evidence passes.

### M5 — Signed Bundle And Offline Dependency Closure

**Goal:** make PostgreSQL an ordinary signed appliance component, not an
installer-time dependency.

Implementation in `appliance-release`:

- Add a `deps/postgresql/` seed package with pins, build/push helpers,
  Makefile, README, and both architecture handling.
- Add the PostgreSQL image/chart/operator input to the common online/offline
  packaging path. Offline misses fail closed and never fall back upstream.
- Extend release-input, final-bundle assembly, signatures, image references,
  validation fixtures, and pack selection where required.
- Update offline dependency documentation and validator assertions.

Exit gate:

- both online and offline release assembly resolve the same pinned PostgreSQL
  component through their respective source policy;
- the final signed bundle contains every database runtime artifact required by
  the first deployment profile;
- release intake fails closed if any required PostgreSQL artifact is absent or
  has an invalid digest;
- `make verify` passes in `appliance-release` and `appliance-ctl`.

### M6 — Coordinated Backup, Restore, And Configuration Revisions

**Goal:** replace local K3s-directory copying as the authoritative recovery
model and add safe configuration replay.

Implementation in `appliance-ctl` and `appliance-code`:

- Version the recovery-set manifest and add component-level checksums,
  encryption/authentication metadata, compatibility requirements, and a
  restore plan.
- Back up PostgreSQL using a PostgreSQL-aware consistent backup mechanism;
  validate restoration into an isolated target before claiming backup success.
- Back up K3s through etcd snapshots and its explicit recovery material, not
  by copying a live local datastore directory.
- Include keys/certificates, metadata bundles, resolved deployment values,
  artifact/blob data with consistency evidence, and explicitly labelled
  node-local assets.
- Add a configuration-revision model: validate, persist/audit, apply via the
  appliance reconciler/Helm, observe rollout, and mark applied/failed/rolled
  back.
- Do not use full database restore as routine configuration rollback.

Exit gate:

- clean-node restore proves control-plane login, data access, registry/blob
  integrity, and applicable workflow functionality;
- a configuration revision survives restart and can be replayed safely;
- incompatible recovery sets fail before target mutation;
- secrets are absent from manifests, logs, evidence, and support bundles.

### M7 — Measurement, Upgrade, And Release Qualification

**Goal:** establish supportable single-node resources and prove continuity.

Required evidence:

- idle and representative-load CPU, RSS, storage, WAL growth, IOPS, and
  startup time on both supported architectures;
- authentication, audit writes, API concurrency, workflow reconciliation,
  backup, restore, and upgrade measurements;
- database-full, disk-full, unavailable database, failed migration, and
  interrupted backup/restore tests;
- fresh install, SQLite-to-PostgreSQL upgrade, N-1 upgrade, rollback by
  recovery-set restore, and clean-node restore;
- public-egress-denied installation/runtime tests;
- cross-repository packaging → preload → chart values → control plane →
  observable success walk.

Exit gate:

- documented supported minimum host resources replace provisional limits;
- every edited repository passes `make verify`;
- no known release producer/consumer mismatch remains;
- release notes document the state-migration and recovery requirements.

## Configuration Replay Versus Disaster Recovery

Configuration changes must become normal application state rather than
ad-hoc edits to Helm values or database rows:

```text
validated desired configuration
  → immutable revision + audit event
  → reconciler/Helm application
  → readiness and rollout observation
  → applied, failed, or rolled-back revision state
```

The recovery path is intentionally separate:

```text
verified, compatible recovery set
  → clean supported target
  → infrastructure/database/data restoration
  → schema and dependency checks
  → appliance smoke checks
```

When importing configuration into a different cluster, preserve only the
explicitly portable logical configuration. Never casually copy cluster CA,
K3s server tokens, node identity, TLS private keys, or enrollment secrets.

## Deferred Profiles And Prerequisites

Future profiles may include `multi-node-postgres-v1`,
`ha-postgres-v1`, and a cloud-managed PostgreSQL profile. None is eligible
until it explicitly defines and proves:

- control-plane replica count and singleton maintenance/leader election;
- PostgreSQL topology, failover, replication, split-brain/partition behavior,
  anti-affinity, and storage assumptions;
- network encryption/authentication and credential rotation;
- backup/WAL retention, RPO/RTO, and clean-cluster restore;
- upgrade, rollback, operator/controller lifecycle, and air-gap closure;
- measured resource envelopes and failure evidence.

Adding one of these profiles must be an additive signed-contract change, not
a reinterpretation of `single-node-postgres-v1`.

## Start Checklist

Before implementation begins:

- [ ] Assign owners for M0–M7 across the three repositories.
- [ ] Confirm whether any released SQLite appliance must be migrated, or
      whether this lands before the first production release.
- [ ] Choose the PostgreSQL distribution/chart/operator candidate and perform
      its air-gap, licensing, supply-chain, UID/GID, backup, and upgrade
      review.
- [ ] Agree on the recovery-set encryption/key-management boundary.
- [ ] Add a cross-repo tracking issue/epic whose completion requires every
      milestone exit gate, not merely the adapter implementation.
- [ ] Do not begin real-host deployment or release-flow execution without an
      explicit per-run authorization.

