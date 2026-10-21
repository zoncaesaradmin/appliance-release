# Configuration Backup, Restore, and Recovery Plan

## Status and decision

**Status: active execution plan. Portable configuration capture, encrypted
file export/import, clean-target validation, and PostgreSQL-backed revisions
are implemented. Installer bootstrap restore and a complete disaster-recovery
set are deliberately not yet supported.**

The appliance must treat configuration replay and disaster recovery as two
different operations:

- PostgreSQL is the authoritative live store for control-plane desired state.
- A portable, encrypted, authenticated configuration archive is the unit for
  moving desired configuration to a fresh appliance or another cluster.
- A recovery set is a broader, explicitly selected disaster-recovery artifact;
  it can include a consistent PostgreSQL backup and selected dependent data.

The default installation behavior remains a clean, signed-release bootstrap.
An installer must never discover and import an arbitrary backup automatically.
Restoring saved configuration is an explicit operator choice.

This plan extends the PostgreSQL/deployment-profile plan. Its M5 recovery work
is incomplete until this document's contracts and gates are met.

## Review baseline (2026-10-21)

The following is the exact starting point for this execution plan. It prevents
us from describing an internal building block as a finished backup feature.

| Area | What exists now | What it does **not** provide yet |
| --- | --- | --- |
| Local database runtime | One PostgreSQL primary is deployed as `controlplane-database` in `ace-infra`, with its own appliance-owned durable directory. The control-plane connects using a DSN, so the connection endpoint can be local or managed/cloud PostgreSQL. | HA, provider-specific managed-PostgreSQL lifecycle, a portable logical database backup, or a restore procedure. |
| Control-plane persistence | Production uses the generic `sqlstore` PostgreSQL provider, with advisory migration locking; local SQLite is retained only for local/test use. | PostgreSQL-native migration definitions (rather than the compatibility SQL translation) and recovery-set database hooks. |
| Desired-configuration foundation | Immutable configuration revisions, canonical payload digesting, metadata-identity validation, clean-target import, an authenticated same-appliance archive, and control-plane revision/archive APIs are implemented in `appliance-code`. | Import preview/reconcile status and installer bootstrap integration. A revision archive is still not a full appliance backup. |
| Operator archive commands | `zonctl configuration-export` and `configuration-import` provide a portable AES-256-GCM archive, protected by an operator-supplied 32-byte key file, over the same HTTPS configuration API for local or cloud PostgreSQL targets. | Bootstrap-time restore before normal operator authentication exists, archive listing/retention, and a recovery-set command. |
| Current command safety | `zonctl backup`, restore, upgrade rollback, and factory-reset backup validation fail closed for a PostgreSQL appliance rather than silently using the legacy K3s-directory snapshot. Bootstrap mode names are accepted syntactically, while only `fresh` is executable. | A PostgreSQL-aware recovery set, `restore-config`, `restore-recovery-set`, or `adopt` path. |
| Blob storage | Blob storage is a distinct local storage domain. | Proof that it is off-appliance or covered by a backup. It must not be assumed durable merely because it uses an object-storage API. |

The first implementation rule is therefore: **do not remove the current
fail-closed guards until their replacement passes the associated exit gate.**

## Findings that require correction before recovery is claimed

| Finding | Current behavior | Required correction |
| --- | --- | --- |
| `zonctl backup` scope | Copies K3s data and staged metadata bundles. | Do not report success for a PostgreSQL-backed appliance until PostgreSQL is captured by a PostgreSQL-aware mechanism. |
| PostgreSQL data | Local PostgreSQL uses `/data/zon/controlplane-database`, outside the K3s data directory copied by the current backup. | Capture a consistent logical PostgreSQL backup; never copy its live data directory as the database backup protocol. |
| Blob data | Local blob storage uses a separate host path and is not captured by the current backup. | Include selected blob objects only when the chosen backup class requires them, with a manifest proving the selected scope. |
| Configuration model | Configuration is spread over PostgreSQL tables, signed metadata files, Helm values, Kubernetes Secrets, and host identity. | Define one versioned desired-configuration export model and explicit inclusion/exclusion rules. |
| PostgreSQL implementation | Production wiring now uses `storage/sqlstore`, including advisory migration locking; the old unselected PostgreSQL stub has been removed. | Replace compatibility migration translation with PostgreSQL-native migration definitions before a recovery-set feature is supported. |
| Existing database on install | Installation has no explicit, user-visible fresh/adopt/config-restore/recovery-restore choice for a non-empty database. | Add fail-closed bootstrap modes and record the selected source in installed-state/evidence. |

Until the first correction lands, `zonctl backup` must either reject the
PostgreSQL deployment profile or mark it unsupported and exit non-zero. It
must not create a successful-looking backup that omits the control-plane
database.

## Current persistence inventory

### PostgreSQL-backed control-plane state

The control plane persists more than a simple settings document: users and
roles, password/token/session material, throttling, audit history, operations,
registry grants, DNS records, licensing, custom profiles and activation,
metadata-bundle references, builder catalog, application definitions and
instances, builds, workspaces, jobs, focus content, WebUI grants, and
idempotency/maintenance data.

The configuration archive must **not** blindly copy all of this state.

### Outside PostgreSQL

The following are separate ownership domains and must not be confused with
application configuration:

- signed release defaults, profile definitions, charts, and immutable images;
- control-plane process configuration rendered from Helm values/ConfigMaps;
- Kubernetes Secrets, including the database DSN and generated credentials;
- appliance/node identity, network names and addresses, TLS material, and K3s
  credentials;
- signed metadata bundle files, for which the database currently records only
  active/previous references;
- user file/video/blob content, local model caches, workspaces, and runtime
  workload state.

The existing S3-compatible blob service is appropriate for objects, but its
local appliance instance shares the appliance failure domain. It is not an
off-appliance backup merely because it is object storage.

## Recovery classes and inclusion policy

| Class | Purpose | Includes | Explicitly excludes by default |
| --- | --- | --- | --- |
| Configuration archive | Replay desired appliance behavior on a fresh target. | Custom profiles and activation, DNS desired records, builder catalog, application definitions/desired state, approved configuration revisions, metadata bundle identity, and resolved compatibility metadata. | Password hashes, API/session/reset tokens, audit history, jobs/builds/operations, observed state, K3s credentials, database DSN, target host identity, and general user/blob content. |
| Security/identity extension | Deliberately preserve identity/security state when policy allows it. | Named, reviewed identity data and required key references. | Secrets in plaintext, unless the recovery set uses the dedicated encrypted secret-material path. |
| Recovery set | Recover a failed appliance or cluster under a separate destructive workflow. | Consistent PostgreSQL logical backup, configuration archive, metadata bundles, resolved deployment values, required keys/certificates, selected blob data, K3s recovery material, and node-local assets explicitly labelled by node. | Anything not declared in the manifest. |

Licensing and custom identity policy need an explicit product decision before
implementation. The default configuration archive should carry a license
*reference/status* only, not silently transfer an entitlement or its private
material to another appliance.

## Target architecture

```text
                 PostgreSQL (authoritative live desired state)
                                    |
                  transactionally create configuration revision
                                    |
                         canonical configuration export
                                    |
              encrypted + authenticated archive and manifest
                       /                              \
       local, operator-exported file          configured backup target
       (air-gapped transfer)                  (external S3-compatible store)
                       \                              /
                         explicit zonctl bootstrap mode
                                    |
                     fresh target validates then imports
                                    |
                 reconciler applies and records result
```

The archive must be portable without public internet access. A cloud profile
may use managed PostgreSQL and cloud object storage, but it uses exactly the
same control-plane configuration APIs, archive schema, validation rules, and
restore state machine. Only the configured DSN and `BackupTarget` adapter
differ.

## Required contracts

### Configuration repository and revisions

`appliance-code` will add a backend-neutral configuration domain contract:

- `ConfigurationRepository` reads/writes the supported desired-configuration
  aggregate, not raw tables;
- every accepted update creates an immutable `ConfigurationRevision` with
  schema version, creator, timestamp, canonical payload digest, validation
  result, and apply/reconciliation status;
- export reads one validated revision under a consistent transaction/snapshot;
- import validates the entire archive before changing the destination and
  records an auditable import/reconciliation result;
- the PostgreSQL provider is the production implementation; interfaces are
  independent of appliance-local versus managed-cloud PostgreSQL.

The generic `storage.DB.Backup(destPath)` contract is not sufficient for this
work. Replace or narrow it so that a database provider is never asked to
pretend that a local file copy is a complete recovery protocol. PostgreSQL
logical backup belongs to a coordinated recovery-set service.

### Archive format

Use a versioned archive with a small, inspectable manifest and encrypted
payloads. The manifest contains no secret values.

Required manifest fields:

- archive format and semantic schema version;
- archive ID, creation time, producer version, platform/release compatibility
  range, deployment-profile schema/version, and PostgreSQL migration level;
- configuration revision ID and canonical payload digest;
- metadata bundle version/digest/signature requirements;
- declared component inventory, per-object checksums, encryption/authentication
  algorithm and key reference, and restore class;
- source identity as evidence only, with target-identity handling policy;
- required operator confirmations and incompatibility reasons.

The archive format must support a local file path for air-gapped transfer.
An optional `BackupTarget` can store the exact same bytes remotely. Do not
make a network URI mandatory at installation time.

### Backup target interface

Define one target interface with operations to write, enumerate, verify, and
read immutable archive objects. Initial adapters:

1. local staging/export path for disconnected operator transfer;
2. the appliance blob service as a convenience/cache target only;
3. external S3-compatible object storage as the recommended resilient target;
4. a cloud object-store adapter, if required, behind the same interface.

Every target must use a dedicated backup prefix/bucket and credentials distinct
from ordinary file/video content. The local appliance blob target alone must
be labelled "same-appliance" and cannot satisfy an off-appliance recovery
policy.

### PostgreSQL recovery

Create a dedicated recovery-set coordinator. For local PostgreSQL it runs a
consistent, pinned PostgreSQL logical backup such as `pg_dump` in custom or
directory format, verifies it in an isolated disposable PostgreSQL target,
and records the result before declaring success. It must not copy
`PGDATA` while PostgreSQL is live.

Cloud-managed PostgreSQL needs a provider adapter that can either create a
portable logical export with the same compatibility contract or identify a
provider-native snapshot in the manifest. A cloud-only snapshot alone is not
portable configuration transfer.

Point-in-time recovery/WAL archiving and PostgreSQL HA are later availability
work, not prerequisites for the first portable configuration archive.

## Install and restore state machine

The installer must expose one explicit bootstrap source. Names below are
contract names; final CLI spelling follows the public CLI review.

| Bootstrap mode | Preconditions | Result |
| --- | --- | --- |
| `fresh` (default) | Destination database/storage is empty or explicitly reset. | Apply signed defaults, create target-local identity and secrets, initialize an empty configuration revision. |
| `restore-config` | Fresh destination; supplied configuration archive verifies and is compatible. | Initialize platform, import desired configuration, reconcile it, and retain target-local identity/secrets. |
| `restore-recovery-set` | Clean target and separate destructive confirmation; recovery set fully verifies. | Restore declared database/data/key components according to the recovery manifest, then validate and reconcile. |
| `adopt` | Existing PostgreSQL state proves appliance ownership and compatibility. | Retain existing state after validation; no archive is implicitly imported. |

If the database or its local storage is non-empty, installation stops before
mutation unless the operator selects `adopt`, `restore-config`, or an explicit
reset/recovery path. `fresh` must never overwrite it silently.

An interrupted import remains recoverable: the destination stays in a
recorded restoring state, the control plane does not serve partially applied
configuration, and rerun either resumes safely or rolls back to the
pre-import clean state. No import can merge unknown pre-existing state.

## Ordered execution plan

### Implementation snapshot and remaining execution order

The following order is the working checklist. It separates changes already
made from the changes still required, so a completed primitive is not mistaken
for a complete recovery promise.

1. **Preserve the archive contract (implemented; verify on every change).**
   Keep the versioned manifest/payload digest contract shared by
   `appliance-code` and `appliance-ctl`; control-plane-local archives use the
   target-local archive key, while portable `zonctl` archives use an
   operator-supplied key. Verify ciphertext before any target mutation.
2. **Complete installation-time configuration restore.** Add an explicit
   `--bootstrap-mode restore-config` input set to `zonctl install`: archive
   path, protected key descriptor/file, and an explicit confirmation. Stage
   and verify it before Helm mutation; bootstrap a clean platform with a
   narrowly scoped installer-to-control-plane import credential; import once;
   reconcile; revoke the credential. `fresh` remains the default and no mode
   may overwrite non-empty database storage.
3. **Add reconciliation and import observability.** A successful database
   import must produce an auditable `pending`, `applying`, `applied`, or
   `failed` result and health/evidence records. Restart must resume or safely
   retry deterministic work rather than present partially applied desired
   state as ready.
4. **Introduce target storage as an optional delivery concern.** Promote the
   existing file and S3-compatible archive target adapters to an operator
   interface for retention/list/read/verify. Appliance blob storage may be a
   convenience target but must be labelled same-appliance; an external S3
   target is the resilient option. Cloud object storage is another adapter,
   not a different archive/API model.
5. **Build the distinct recovery-set feature.** Use a pinned `pg_dump`/
   restore workflow and isolated verification; add explicitly selected blob,
   metadata, values, certificates, and node-local inputs to a signed manifest.
   Do not copy live `PGDATA`, and do not change the existing fail-closed legacy
   backup behavior until this gate passes.
6. **Finish PostgreSQL-native schema lifecycle and qualify.** Move remaining
   translated migration definitions to PostgreSQL-native form, retain advisory
   locking and schema-version refusal, then run the full cross-repository
   scenario matrix from signed bundle through fresh-target restore with no
   public egress.

### Corrections discovered during implementation

- The archive encryption key is control-plane-local. It must be generated in
  the `ace-system` source Secret but **must not** be replicated to `ace-apps`,
  where no workload uses it. Replicate only shared session/signing/pepper
  material; this avoids needless secret distribution.
- A portable archive cannot reuse the target-local archive key: another
  appliance cannot decrypt it. The cross-appliance CLI therefore uses a
  distinct, operator-controlled key and the canonical revision API. This is
  the same interface for an on-premise or cloud PostgreSQL endpoint.
- Local blob storage is not an off-appliance backup. Any UI or documentation
  that calls it a backup target must show its failure-domain limitation.
- Existing `backup`/`restore` success semantics remain invalid for PostgreSQL
  until the recovery set exists. Their current rejection is intentional
  protection, not a missing compatibility path.

### P0 — Correct the current safety claim

- In `appliance-ctl`, detect the PostgreSQL deployment profile in `backup`,
  `restore`, upgrade rollback, and factory-reset backup validation.
- Make current file-copy backup unsupported for that profile until the new
  coordinator exists; update operator messages, docs, tests, and evidence.
- Audit every current caller that assumes a K3s directory snapshot is a full
  appliance backup.

**Exit gate:** no command can report a restorable PostgreSQL appliance backup
while omitting the control-plane database.

### P1 — Freeze semantics and native PostgreSQL foundation

- Publish the inclusion matrix above as product/API contract and settle the
  licensing/identity policy.
- Complete the native PostgreSQL repository set and native migration history;
  remove production dependence on the SQLite-named compatibility adapter.
- Add migration/advisory locking, dirty/newer schema refusal, bounded query
  timeouts, and PostgreSQL integration tests.

**Exit gate:** every current repository contract passes against native
PostgreSQL and no production PostgreSQL code path uses SQLite migrations or
the unimplemented PostgreSQL backup method.

### P2 — Configuration revisions and canonical export/import

- Implement the configuration aggregate, revision tables, repository,
  validation, audit events, export, import preview, and apply status.
- Implement deterministic canonical serialization and archive manifests.
- Add encryption/authentication with target-independent key references; never
  place secret values in CLI arguments, logs, manifests, or support bundles.
- Add the reconciler that materializes configuration safely into downstream
  systems and records observed success/failure.

**Exit gate:** a configuration revision survives process/database restart and
can be exported, verified, imported into a clean PostgreSQL target, and
reconciled without raw-table copying.

### P3 — Archive storage and operator operations

- Implement local file export/import first for the air-gapped path.
- Implement the `BackupTarget` interface and initial S3-compatible adapters;
  isolate backup credentials and prefixes from user blob data.
- Add archive listing, verification, retention metadata, evidence, and
  explicit operator confirmation for import/restore.

**Exit gate:** a disconnected archive can be copied by the operator and
validated before target mutation; external object storage is optional, never
an install-time internet dependency.

### P4 — Coordinated recovery set

- Add PostgreSQL logical dump/restore tooling as a signed, pinned product
  capability and validate restore in an isolated target.
- Capture metadata bundles, resolved deployment values, selected blob objects,
  K3s recovery material, and explicitly scoped node-local assets.
- Implement recovery-set restore sequencing, key/certificate policy, and
  integrity/compatibility gates.

**Exit gate:** clean-node recovery is demonstrated without copying a live
database directory or assuming all storage is on the control-plane node.

### P5 — Installer bootstrap modes

- Add `fresh`, `restore-config`, `restore-recovery-set`, and `adopt` as
  explicit install choices with mutually exclusive inputs.
- Stage and verify a supplied archive before Helm/control-plane mutation.
- Record bootstrap source, archive/recovery-set ID, compatibility outcome, and
  resolved deployment-profile digest in installed state/evidence.

**Exit gate:** all four modes fail closed on ambiguity, corruption, incompatible
release/schema, missing metadata, or non-empty unselected destination data.

### P6 — Qualification and documentation

- Add API, database, chart, installer, packaging, upgrade/rollback, and
  cross-repository end-to-end tests.
- Document the operator distinction between configuration export, backup
  target, recovery set, factory reset, and restore.
- Measure backup/restore duration, archive size, database/WAL growth, and
  resource impact for the supported single-node profile.

**Exit gate:** each edited repository passes `make verify`; a full signed
bundle → install → export → factory reset/new target → restore → verification
run succeeds with public egress denied.

## Repository responsibilities

| Repository | Responsibilities |
| --- | --- |
| `appliance-code` | Native PostgreSQL storage/migrations; configuration aggregate and revisions; archive validation/export/import API; reconciler; recovery hooks; chart support for backup jobs/tools. |
| `appliance-ctl` | Fail-closed current backup behavior; archive/recovery orchestration; bootstrap modes; staging; evidence; target and ownership checks; factory-reset/upgrade integration. |
| `appliance-release` | Signed artifacts required by recovery tooling; release-input/bundle validation; offline dependency seed/remap; cross-repository contract and air-gap tests. |

## Required scenario matrix

- ordinary pod/control-plane restart retains PostgreSQL desired configuration;
- fresh installation starts from signed defaults only;
- configuration archive import restores desired configuration to a new
  single-node appliance while retaining its target identity and secrets;
- the same archive imports into a cloud-managed PostgreSQL deployment through
  the same API contract;
- full recovery set restores a failed appliance from a clean target;
- corrupted, unsigned/unauthenticated, incompatible, incomplete, or replayed
  archives fail before destination mutation;
- interrupted export, import, and restore recover deterministically;
- blob-dependent configuration detects missing declared objects;
- multi-node topology never mistakes a worker's node-local models/workspaces
  for shared control-plane configuration;
- no command needs public internet access and no secret escapes manifests,
  logs, evidence, CLI arguments, or support bundles.

