# Automation Runtime Plan

## Purpose

This document defines the architecture and packaging contract for adding the
Automation Runtime, a generic metadata and DSL execution service, to the
appliance.

The core direction is:

- keep the workflow runtime and execution support in the software bundle
- let vendor-signed metadata bundles add or revise workflow definitions without
  rebuilding the whole appliance binary every time
- treat dynamic workflow definitions as metadata content, alongside profiles,
  capabilities, UI policy, notifications, and MCP tool descriptors
- move complete metadata-bundle ownership to Automation Runtime and make other
  services consume active metadata through it

## Current Baseline

The current cross-repo state already gives us part of the foundation:

- `appliance-release` packages exactly one signed
  `appliance-metadata-bundle-X.Y.Z.N.tar.zst` into `release-input`
- `appliance-ctl` stages and extracts that archive into
  `/data/zon/metadata-bundles`
- `appliance-code` control-plane logic can validate, install, activate, and
  roll back metadata bundles dynamically
- the control plane currently loads typed metadata sections such as
  `profiles/` and `capabilities/`
- the appliance already has a separate Argo-backed runtime for developer flows;
  that runtime is not the execution engine for Automation Runtime

What is missing is the Automation Runtime service, its metadata-bundle contract,
and its restricted Open Workflow execution engine.

## Product Direction

Workflows are not a separate installer-side product bundle.

Instead:

- the software bundle provides the execution engine, APIs, runtime images, and
  safety controls
- Automation Runtime is part of the foundation and the universal `base`
  capability, independent of the developer workflows/Argo pack
- the active metadata bundle provides named workflow-bearing metadata sections
  that extend what the appliance can do
- a metadata-bundle update may add, remove, disable, or revise supported
  workflows only for behavior already supported by the installed software
- any workflow requiring new binaries, new images, new step runtimes, new host
  packages, or new Kubernetes services still requires a full software bundle
  update

This preserves the existing invariant:

- metadata updates change signed product policy and declarative behavior
- software updates change code and runtime artifacts

## Metadata Bundle Lifecycle

Automation Runtime is the sole authority and writer for the complete metadata
bundle after this service is introduced. The control plane keeps the existing
northbound API, authentication, RBAC, and UI behavior, but uses Automation
Runtime for bundle status, validation, installation, rollback, and all active
bundle content it consumes.

Every software release carries an immutable, verified base metadata bundle. The
installer stages that bundle before Automation Runtime starts. It is never
overwritten by a dynamic upload and is always available as the fallback bundle
for that software release.

Dynamic bundle lifecycle:

1. receive and stage the uploaded archive without changing active state
2. verify its signature, digest, archive safety, metadata schema, and software
   compatibility
3. parse every declared section, validate referenced schemas and actions, and
   compile all supported Open Workflow definitions
4. construct a complete replacement in-memory registry
5. atomically make the staged bundle and compiled registry the active generation
6. retain the previously installed compatible versions for rollback

Rollback may target any retained bundle version compatible with the running
software. If no target is supplied, it selects the immediately previous active
version. The release-provided base bundle is always a valid rollback target.
Until a retention policy is added, installed compatible versions are retained.
An upload must never overwrite the base bundle or replace existing content under
the same metadata version with a different digest.

After a software upgrade, the new release's base metadata bundle becomes the
fallback. Dynamic bundles from an incompatible software version may remain for
diagnostics or backup purposes, but must not be activated.

If the selected dynamic bundle cannot be verified or compiled during startup,
the runtime must not execute it. The runtime activates the verified base bundle
and records a high-severity audit and operational event describing the recovery.

## Workflow Model

The metadata bundle should stay flat at the top level.

Do not add a generic top-level `workflows/` directory, and do not add nested
"bundles inside bundles" below it.

For now, keep only these workflow-bearing top-level sections:

- `mcp-tools/`
- `debug-tools/`

Initial directory shape:

```text
appliance-metadata-bundle-4.3.2.1/
  bundle.yaml
  profiles/
    catalog.yaml
  capabilities/
    catalog.yaml
  activation/
  ui/
  notifications/
  mcp-tools/
    README.md
  debug-tools/
    README.md
    allowed-apis.yaml
    workflows/
      export-audit-events.dsl.yaml
    schemas/
      export-audit-events.input.schema.json
      export-audit-events.output.schema.json
```

The release-side contract fixture for this structure lives under
`docs/examples/metadata-bundle-contract/appliance-metadata-bundle-4.3.2.1/`.

Initial `debug-tools/README.md` shape:

```md
# Debug Tools

Vendor-signed debug workflows that the appliance runtime can load dynamically.

## Contents

- `workflows/export-audit-events.dsl.yaml`
- `allowed-apis.yaml`
- `schemas/export-audit-events.input.schema.json`
- `schemas/export-audit-events.output.schema.json`
```

Illustrative API allowlist file:

```yaml
apiVersion: metadata.zon/v1alpha1
kind: AllowedAPIs
apis:
  - id: audit.export.create
    function: zon:api:audit.export.create
    method: POST
    path: /api/v1/audit/exports
```

This file is a signed declaration of which platform API actions workflows in
the section may use. Its detailed schema and validation rules will be refined
with the first implementation. It can only select actions already implemented
and approved by the installed software; metadata cannot introduce a new API,
endpoint, credential, or permission.

Sample Open Workflow DSL file:

```yaml
  document:
    dsl: '1.0.3'
    namespace: zon.debug-tools
    name: export-audit-events
    version: '1.0.0'
    title: Export Audit Events
  input:
    schema:
      format: json
      resource:
        endpoint: schemas/export-audit-events.input.schema.json
  output:
    schema:
      format: json
      resource:
        endpoint: schemas/export-audit-events.output.schema.json
  do:
    - createAuditExport:
        call: zon:api:audit.export.create
```

Bundle-local resource paths are resolved from the containing metadata section,
so `schemas/...` above resolves under `debug-tools/`. Remote schema resolution
is not allowed.

Sample input schema:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "additionalProperties": false
}
```

Sample output schema:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "properties": {
    "exportId": { "type": "string" },
    "status": { "type": "string" }
  },
  "required": ["exportId", "status"],
  "additionalProperties": false
}
```

## Execution Contract

The runtime should load workflows from the active metadata bundle and compile
them into an internal typed representation before execution.

Execution should remain appliance-owned.

The intended split is:

- use Open Workflow Specification DSL `1.0.3` and pin
  `github.com/open-workflow-specification/sdk-go/v4` at `v4.0.0` for parsing
  and structural validation
- do not hand final execution control to a third-party runtime
- convert supported workflow definitions into an internal execution plan
- execute only appliance-approved step kinds

Initial supported step kinds should stay narrow:

- sequential `do` tasks
- `call` tasks that reference symbolic `zon:api:` actions declared by the
  section allowlist and implemented by the installed software
- typed workflow inputs and outputs using bundle-local JSON Schemas
- the minimum input/output mappings needed by the first example

Deferred for a later phase:

- arbitrary script execution
- Starlark steps
- shell execution
- remote fetch or internet-dependent steps
- raw HTTP, OpenAPI, gRPC, A2A, or MCP endpoints
- schedules, event listeners, parallel branches, waits, retries, and nested
  workflow execution

## Safety Rules

The generic workflow engine must preserve existing appliance invariants.

Rules:

- workflow definitions must come only from the active signed metadata bundle
- production verification must use the appliance's trusted vendor signing
  roots; development signature bypasses must not be accepted in production
- the engine must fail closed on unknown step kinds, invalid references, or
  unsupported spec features
- workflows must not download code, plugins, packages, or images at runtime
- workflows must execute only against already-installed appliance capabilities
- workflow calls must resolve to software-registered symbolic actions; bundle
  metadata may narrow the action set but may not expand it
- bundle content must not provide credentials, authorization tokens, arbitrary
  headers, or service destinations
- JSON Schema and other external-resource references must resolve within the
  active metadata section; network resolution and path escape are rejected
- workflow definition updates must be reversible via metadata-bundle rollback
- control-plane APIs must continue to enforce RBAC and capability checks even
  when invoked from workflow steps

## Open Workflow Scope

The first implementation targets Open Workflow Specification DSL `1.0.3` and
uses Go SDK `github.com/open-workflow-specification/sdk-go/v4` at `v4.0.0` for
parsing and structural validation. The module remains pinned in `go.mod` and
`go.sum`; changing it requires explicit compatibility validation.

Initial support is:

- parse supported Open Workflow documents
- perform schema and structural validation
- reject unsupported constructs with explicit validation errors
- compile only the supported subset into internal steps

This means “Open Workflow compatible” initially is understood as:

- specification-aware parser and validator
- partial execution support for the appliance-approved subset

It should not mean:

- execute every legal Open Workflow feature
- embed a general-purpose remote runtime
- allow arbitrary dynamic actions
- claim conformance with the complete Open Workflow conformance test kit

## Cross-Repo Ownership

This repository owns only the packaging and signed-input contract.

Expected ownership split:

- `appliance-release`
  - package the metadata bundle into `release-input`
  - document the metadata-bundle contract
  - keep the component catalog aligned with workflow metadata content
- `appliance-ctl`
  - stage the immutable release-provided base metadata bundle before the runtime
    starts
  - preserve and restore Automation Runtime bundle storage and state through
    appliance lifecycle operations
  - include active bundle and registry-generation status in diagnostics
- `appliance-code`
  - define the `debug-tools/` and `mcp-tools/` metadata layout
  - build the Automation Runtime service, image, and chart
  - migrate complete metadata-bundle ownership out of the control plane
  - compile supported DSL definitions into an internal representation
  - expose the minimal bundle and automation invocation contracts

## Runtime Service

Automation Runtime is a separate pod and ClusterIP service, but not a separate
product-facing API authority.

The clean split is:

- keep the **control plane** as the northbound API gateway, identity/RBAC
  authority, admin UI backend, and broad appliance coordinator
- make **Automation Runtime** the sole authority for complete metadata-bundle
  storage, validation, activation, rollback, normalized reads, DSL compilation,
  registry management, and execution

That gives us process isolation and a clearer long-term home for workflow
execution without forcing users or administrators to learn a second top-level
API surface on day 1.

### Why a separate service is worth it

- workflow execution and workflow-definition compilation are a different runtime
  concern from user/session/profile/licensing APIs
- we can restart, scale, and instrument workflow handling independently
- future DSL support, bundle watchers, and script sandboxes belong in a more
  isolated process boundary
- MCP-tool-style execution paths can talk to a focused runtime instead of
  bloating the control-plane binary further

### Why not split metadata and workflows into two new services

I agree with keeping metadata-bundle handling and dynamic workflow runtime in
the **same** new service, as long as the service is framed around dynamic
capability rather than only metadata upload.

Metadata upload is infrequent, but bundle activation, workflow compilation, and
workflow execution are tightly related:

- a new bundle changes the executable workflow registry
- validation needs both metadata-bundle checks and workflow-DSL checks
- rollback needs to revert both admin-visible metadata state and runtime
  workflow state together

So the new service should own these as one bounded context.

## Service Name

- canonical service and binary name: `automation-runtime`
- user-facing name: `Automation Runtime`

Reason:

- “automation” is the clearest description of what the service actually does
- “runtime” communicates that this is the process that materializes signed
  dynamic behavior
- the service is broader than metadata upload alone and narrower than the whole
  control plane
- metadata upload is an admin function of that runtime, not its whole identity

## Responsibilities

The new service contains three internal modules, even if they live in one
binary and one pod:

- `bundle manager`
  - own complete metadata-bundle status, validation, staging, activation,
    retained-version rollback, and normalized section reads
- `workflow registry`
  - load active workflow definitions from the active metadata tree, parse them,
    validate supported DSL features, and build a runtime registry
- `execution engine`
  - execute supported workflow steps, call internal handlers or platform APIs,
    and report status/logs/results

MCP tools should resolve to the same generic automation execution path. They do
not need a separate tool-specific runtime API or execution subsystem.

## API Contract

Do not expose every new API directly to end users from day 1.

Use a two-surface model:

- **northbound admin and user APIs** remain on the control plane
- **internal runtime APIs** live on the new service

### Control-plane-facing APIs

These remain stable user/admin entry points. The control plane authenticates,
authorizes, audits, and proxies them to Automation Runtime:

Use `automations` in the public API. Avoid `workflows` because it is too easily
confused with Argo Workflows and the internal execution substrate.

Keep the initial API surface deliberately small. The existing metadata-bundle
APIs remain the administrative contract:

- `GET /api/v1/appliance/metadata-bundle`
- `POST /api/v1/appliance/metadata-bundle/validate`
- `POST /api/v1/appliance/metadata-bundle/install`
- `POST /api/v1/appliance/metadata-bundle/rollback`

The rollback request may contain an optional target metadata version. Without a
target, Automation Runtime selects the immediately previous active version. The
status response includes the immutable base version and retained compatible
versions so an administrator can select a target without a separate listing API.

The only automation API in the initial synchronous execution path is:

- `POST /api/v1/appliance/automations/{automationId}/invoke`

`automationId` is the stable Open Workflow document identity encoded as
`<namespace>:<name>`, for example
`zon.debug-tools:export-audit-events`. A bundle may contain only one active
document version for an automation ID. The document version, metadata-bundle
version, and bundle digest are recorded with every invocation.

The request body is the workflow's JSON input. The synchronous success response
contains the automation ID, document version, metadata-bundle version, and
schema-validated JSON output. Errors use the control plane's standard problem
response. Client cancellation is propagated, the runtime enforces a configured
maximum execution time, and the initial implementation performs no implicit
action retries.

Discovery, standalone input-validation, asynchronous run status, and log APIs
are added only when a concrete caller requires them.

### Runtime-internal APIs

These are the minimum calls needed between the control plane and Automation
Runtime, internal-only on ClusterIP plus service-to-service authentication:

- `GET /internal/v1/metadata-bundle`
- `POST /internal/v1/metadata-bundle/validate`
- `POST /internal/v1/metadata-bundle/install`
- `POST /internal/v1/metadata-bundle/rollback`
- `POST /internal/v1/automations/{automationId}/invoke`

The internal read returns the active bundle generation, manifest, status, and
normalized section content needed by control-plane consumers. It is the generic
bundle read contract; separate profile, capability, domain, or tool read APIs
are not introduced initially.

Install and rollback both perform activation. They must validate and atomically
replace active bundle state and the compiled registry before returning success.
Service startup loads the selected active generation through the same internal
activation path.

Do not add domain, registry-reload, tool-specific, discovery, run-status, or
log endpoints until their behavior is required by an implemented caller.

## Control Plane Integration

The control plane should still own:

- user authentication
- RBAC and entitlement checks
- audit identity
- public API shape
- admin UI aggregation

The control plane must stop reading bundle files or maintaining a separate
active/previous bundle database after migration. Profile, capability, UI,
notification, and other bundle-backed consumers use the normalized active
bundle returned by Automation Runtime and may cache it by immutable generation
or digest.

The control plane fetches the active generation during startup, invalidates its
cache after each successful install or rollback response, and uses generation or
digest validation for subsequent refreshes. This requires no reload endpoint.

Automation Runtime does not become a second user identity system.

Request flow:

1. client calls control-plane API
2. control plane authenticates and authorizes
3. control plane resolves the caller and invocation permission
4. control plane forwards an internal request to the runtime service with:
   - caller identity
   - audit correlation id
   - short-lived delegated token or trusted internal service auth
5. runtime validates the delegated identity and executes only software-approved
   actions allowed by the active signed bundle
6. control plane writes or supplements the audit trail and returns the public response

This keeps RBAC logic centralized and avoids drift between the control plane and
the runtime service.

## Direct Runtime Access

Runtime APIs are limited to internal machine-to-machine usage.

Good direct callers:

- control-plane backend
- future internal MCP integration through the generic invocation API

Not allowed initially:

- exposing the runtime directly as a general external admin API
- duplicating user/session/token logic there

No external ingress, user login, session handling, or tool-specific invocation
API is added to Automation Runtime.

## Deployment And Storage Contract

Automation Runtime ships in the foundation pack and is enabled by the universal
`base` capability. It does not depend on Argo, the developer pack, or the
`workflows` capability.

The first implementation runs exactly one replica so bundle activation and the
in-memory registry have one authority. The runtime owns:

- read-write access to `/data/zon/metadata-bundles`
- its persisted active/previous/history state on its own service storage
- service logs at `/data/zon/logs/automation-runtime/`

After migration, the control plane does not need direct bundle filesystem
access. The installer may seed the immutable base bundle into the bundle path
before Helm starts, but day-2 writes go only through Automation Runtime.

The chart must assign a distinct fixed numeric UID/GID, use the appliance shared
filesystem GID where required, run non-root with a read-only root filesystem,
mount only explicit writable paths, comply with Restricted Pod Security, and
define startup/readiness probes and CPU/memory limits. Exact numeric identities
and resource values are allocated with the chart implementation.

An invocation pins the compiled registry generation it started with. Bundle
activation atomically changes the generation used by new invocations and does
not mutate an in-flight execution.

## DSL Contract

The service uses Open Workflow DSL while keeping the executable subset narrow
at first.

Initial DSL support:

- declarative workflow metadata
- typed inputs and outputs
- sequential steps
- symbolic calls to software-approved platform actions
- bundle-local JSON Schema validation
- only the minimum data mapping needed by the sample automation

The initial implementation explicitly rejects:

- arbitrary shell
- remote fetch
- plugin download
- dynamic code execution
- Starlark

Starlark can be revisited in a later phase as a tightly sandboxed step type
inside this same service once we have:

- auditability
- deterministic input/output contracts
- resource controls
- support-bundle visibility

## Integration Plan

The implementation may migrate code in incremental commits, but the released
service boundary has one final ownership model:

1. add the Automation Runtime service, foundation image, chart, storage, and
   health contract
2. move complete metadata parsing, verification, persisted state, install,
   activation, and rollback ownership from the control plane into the runtime
3. change every control-plane bundle consumer to use the runtime's normalized
   active-bundle contract
4. add Open Workflow DSL parsing, supported-subset validation, schema loading,
   symbolic action resolution, and atomic registry construction
5. add the generic synchronous invocation path with delegated identity, RBAC,
   audit, timeout, cancellation, and output validation
6. add the `debug-tools` sample files as a contract fixture, without introducing
   debug-specific runtime behavior or APIs

Do not ship an intermediate dual-writer state. Until migration is complete, the
existing control plane remains authoritative; once Automation Runtime is
enabled, it becomes the only bundle authority.

## First End-To-End Slice

The first slice establishes the generic notions with one
`debug-tools/export-audit-events` example. `debug-tools` is a metadata section,
not an automation domain and not a special runtime subsystem.

The slice contains:

- one valid Open Workflow DSL document
- one workflow input schema and one workflow output schema
- one illustrative `allowed-apis.yaml`
- one symbolic action implemented by the installed software
- one generic public control-plane invocation routed to Automation Runtime

That will prove:

- bundle install changes runtime capability
- atomic active-generation replacement works
- audit and RBAC still hold
- targeted rollback, including rollback to the immutable base bundle, restores
  the prior active generation

## Implementation Order

1. Add and package the base-capability Automation Runtime pod and service.
2. Move the full metadata-bundle lifecycle and active state into the runtime.
3. Move control-plane bundle readers to the runtime contract and remove direct
   bundle ownership from the control plane.
4. Add the pinned Open Workflow parser, restricted compiler, and generation-pinned registry.
5. Add generic synchronous invocation with RBAC and audit coverage.
6. Add the single `debug-tools` example and verify install, invocation, targeted
   rollback, restart recovery, backup/restore, and software upgrade behavior.
7. Add MCP tool mappings only after the generic path is stable.
8. Revisit Starlark only after typed steps, auditing, and rollback behavior are stable.

## Packaging Impact In This Repo

For `appliance-release`, the important contract change is simple:

- the signed metadata bundle is no longer just profile and capability policy
- it is now the signed carrier for dynamic workflow capability as well

No separate workflow-definition artifact should be introduced at the release
layer for this feature unless a later design proves that metadata-bundle
carriage is insufficient.

The release implementation must add the Automation Runtime image and chart to
the foundation component graph and signed manifest independently of the
developer workflows/Argo artifacts.

## Explicitly Deferred

The following do not block the initial implementation and do not receive APIs
or runtime abstractions yet:

- MCP tool mapping
- Starlark or any other script execution
- arbitrary user-authored workflows
- automation discovery and standalone input-validation APIs
- asynchronous runs, persisted execution history, and run-log APIs
- schedules, events, retries, parallelism, waits, and nested workflows
- multiple Automation Runtime replicas
- dynamic-bundle retention and deletion policy
- external schema, catalog, plugin, image, or code retrieval
