# Module Descriptor Rollout Plan

This note captures the recommended rollout plan for moving the appliance from
hardcoded service wiring toward a descriptor-driven modular model, while keeping
the current product simple and preserving a clean path to future runtime-added
modules.

## Intent

We want:

- a simple public product model that remains easy to explain
- an internal modularization model for appliance functionality
- control-plane-owned API exposure with centralized authn/authz/RBAC
- a future path for runtime-added modules and projected application APIs
- no regression to current install, profile, or API behavior

We do not want:

- a large new abstraction stack exposed to operators
- runtime self-registration of arbitrary public routes
- connected licensing behavior or external entitlement checks
- a post-install add-on lifecycle in the first step

## Recommended Model

Keep the public-facing model small:

- `profile`: operator-facing appliance shape
- `capability`: coarse technical feature gate enabled by a profile
- `entitlement`: whether a module is allowed after capability and other policy
  checks are applied
- `module`: internal implementation unit for a product function

The intended relationship is:

- profile is a curated preset
- capability is the technical gate
- entitlement is the allow/deny result
- module is the actual unit resolved and deployed

Use `module` as a logical unit, not a 1:1 Kubernetes primitive. One module may
map to:

- one Deployment and one Service
- multiple Deployments and Services
- a DaemonSet plus supporting resources
- a host-side binary plus an in-cluster proxy
- future workflow/controller-backed resources

## Current State

Today the appliance already has:

- profile selection
- capability mapping
- install-time/config-time selection of enabled functionality
- control-plane proxying of selected backend APIs

Today profiles are product-owned curated combinations of capabilities, and the
profile-to-capability mapping is mirrored in code.

Today the control plane and product config still rely on known built-in
services/routes. That is descriptor-equivalent in intent, but the declarations
are still mostly embedded in code rather than expressed as first-class module
metadata.

## Target State

Near-term target: descriptor-driven static composition.

That means:

- the appliance still knows the candidate modules ahead of time
- profile and capability selection still happen at install/startup time
- entitlement filtering is applied at the same stage
- control-plane route exposure is generated from module descriptors
- services may report readiness/active handlers only within their predeclared
  route surface

This is not yet runtime-dynamic module installation. It is a structured static
model that is intentionally compatible with future dynamic addition.

## Profile Catalog Direction

Profiles should remain operator-facing presets, not the true extensibility
layer.

Recommended stance:

- make the profile catalog metadata-driven over time
- carry the catalog in signed bundle/product metadata
- keep profiles curated and product-owned
- do not allow arbitrary operator-authored profiles on the target in the
  mainline model

Why:

- the true runtime model is capabilities, entitlements, and modules
- arbitrary profile authoring creates a combinatorial support and upgrade
  problem
- untested capability combinations can break module dependency assumptions
- runtime-dynamic extensibility is better handled at the module layer, not by
  inventing more and more profiles

The practical effect is:

- installer reads a signed profile catalog
- operator selects one of the bundled profiles
- selected profile resolves to capabilities
- capabilities plus entitlements resolve to modules
- later runtime add-ons modify the active module set, not the chosen profile

This keeps install UX simple while avoiding a permanently hardcoded profile
mapping in code.

## Descriptor Shape

Introduce an internal module descriptor contract with fields equivalent to:

- `name`
- `kind`
  - examples: `platform`, `application`
- `requiredCapabilities`
- `entitlementKey`
  - optional symbolic name used by entitlement evaluation
- `dependencies`
  - module-level or capability-level dependencies
- `executionMode`
  - examples: `cluster-service`, `host-agent`, `workflow-backed`
- `resources`
  - Kubernetes charts/manifests/images/binaries/config inputs
- `apiExposure`
  - whether the appliance API fronts this module
- `routes`
  - declared proxyable API surface, methods, path prefixes, backend target
- `healthChecks`
- `securityClass`
  - examples: `restricted`, `host-privileged`, `internal-only`

The route surface must be predeclared in the descriptor. Runtime services may
report readiness and activated handlers only within that declared surface.

## Entitlement Model

Use the term `entitlement`, not `license`.

Conceptually:

- capability answers whether the appliance shape supports a module technically
- entitlement answers whether the module is allowed after license/policy/other
  product checks are applied

For the first implementation:

- define an entitlement evaluator interface or method-driven resolver
- return `true` for every known module by default
- keep the interface narrow so later logic can combine capability, product
  policy, license state, and other checks without changing the descriptor model

Recommended shape:

- `IsEntitled(module, context) bool`
- initial implementation always returns `true`

Later, `entitlement` can become a pure function of:

- selected profile
- resolved capability set
- available license data
- platform version / compatibility checks
- local policy or operator configuration

No external entitlement or license callouts are allowed.

## Rollout Phases

### Phase 1: Introduce the descriptor and entitlement types

Goal:

- add the internal model without changing behavior

Work:

- define module descriptor types
- define entitlement evaluator interface
- add a default always-true evaluator
- encode the current built-in platform functions as descriptors
  - `host-agent`
  - `artifact`
  - `dns`
  - `workflows`
  - `build`
  - any other existing control-plane-proxied module

Rules:

- preserve existing profile names
- preserve existing capability names
- preserve the existing curated profile-to-capability combinations
- preserve existing enabled/disabled behavior
- do not alter the public API surface

Exit criteria:

- current built-in services can be represented as descriptors with no behavior
  change

### Phase 2: Switch product-config generation to descriptors

Goal:

- remove hardcoded service/route registration logic from config rendering

Work:

- make product-config generation resolve enabled modules from:
  - selected profile
  - capability set
  - entitlement evaluator
- generate proxied service definitions and route exposure from descriptors
- keep existing route paths and backend URLs stable

Rules:

- resulting config must match current behavior for all existing profiles
- if a module is not allowed, it must fail closed rather than partially render

Exit criteria:

- `core`, `storage`, `builder`, and DNS-bearing profiles produce the same
  effective module exposure they do today

### Phase 3: Align control-plane runtime loading with descriptors

Goal:

- make control-plane exposure logic consume the same descriptor-driven module
  resolution model

Work:

- load only allowed modules at startup
- keep backend health/readiness checks scoped to enabled modules
- allow module services to report runtime readiness within their declared API
  envelope

Rules:

- service runtime must not create new public routes outside the descriptor
- control plane remains the authority for route exposure and RBAC

Exit criteria:

- control-plane module exposure is descriptor-driven rather than service-wired

### Phase 4: Move descriptors into signed product metadata

Goal:

- make module composition part of release metadata rather than code-only

Work:

- define how bundled module descriptors are carried in signed inputs
- validate descriptor/version compatibility during install/startup
- keep install fully offline and bundle-contained

Rules:

- descriptors must be signed/bundled/verifiable like other release inputs
- no network retrieval of descriptors or module packages

Exit criteria:

- module composition is metadata-driven from signed bundle inputs

### Phase 4a: Move the profile catalog into signed product metadata

Goal:

- make profile-to-capability mapping metadata-driven while keeping profiles
  curated

Work:

- define how the bundled profile catalog is carried in signed inputs
- load profile definitions from bundle/product metadata instead of duplicating
  them in code
- validate profile definitions against capability rules and dependency rules

Rules:

- profile catalog remains product-owned and signed
- no arbitrary target-side profile authoring in the normal install path
- existing named profiles remain stable unless intentionally versioned or
  changed

Exit criteria:

- installer/control-plane resolve profiles from signed catalog metadata rather
  than hardcoded tables

### Phase 5: Future runtime-dynamic module lifecycle

Goal:

- support explicit post-install addition/removal of approved modules

Work:

- accept signed module packages at runtime
- validate package trust, compatibility, capabilities, and entitlements
- deploy module resources through an installer-owned or platform-owned
  reconciler
- reload the descriptor registry
- expose the newly approved API surface through the control plane

Rules:

- runtime services report readiness, not authority
- public routes still come only from approved descriptors
- host-level execution remains reserved for trusted platform modules

Exit criteria:

- new modules can be added after install without changing the core descriptor
  model

## Platform Modules vs Application Modules

Plan for two descriptor classes even if only platform modules are implemented
initially:

- `platform module`
  - privileged appliance functionality
  - may use protected namespaces or host access
  - examples: `host-agent`, `artifact`, `dns`
- `application module`
  - operator/user-brought workload
  - stricter sandboxing and namespace isolation
  - no host execution path by default
  - optional appliance-API projection only when explicitly declared and
    approved

This distinction matters for the future "bring your own application" use case.
The same descriptor model can serve both, but the policy class must differ.

## API Exposure Rules

The control plane remains the front door.

Module descriptors may declare:

- backend target
- route prefixes or exact routes
- methods
- versioning expectations
- health endpoints

Runtime services may later report:

- ready or not ready
- active handler subset
- version/build information

Runtime services may not:

- invent new public appliance API routes at runtime
- bypass control-plane authorization
- expose host-level operations without being a trusted platform module

## Non-Breaking Rollout Guardrails

Every phase must preserve current behavior unless a change is explicitly
intended and documented.

Required checks:

- all existing profiles still resolve the same capability sets
- all existing built-in routes remain unchanged
- current host-agent APIs keep working through the appliance API
- install, upgrade, restore, and verification paths remain offline and
  manifest-driven
- bundle portability is preserved
- no current service becomes implicitly disabled by the entitlement layer
- no current curated profile becomes semantically different during the catalog
  migration

Recommended change discipline:

- introduce descriptor types first
- keep old and new resolution paths side by side behind verification until the
  descriptor path proves equivalent
- migrate one built-in module family at a time if needed

## Suggested First Execution Slice

The first delivery slice should be intentionally narrow:

1. add descriptor and entitlement interfaces
2. model the current `host-agent` as a descriptor-backed platform module
3. generate its proxied route declarations from the descriptor
4. leave entitlement always-true
5. confirm profile behavior and host APIs remain unchanged

Then expand the same pattern to the remaining built-in modules.

After that first slice, the next low-risk slice should be to centralize the
curated profile catalog behind one metadata-oriented abstraction, even if the
source is still code-backed initially.

## Cross-Repo Phase 1 Implementation Checklist

This is the recommended first implementation sequence across the currently
relevant repositories.

### `appliance-code`: control-plane module model

Primary touchpoints:

- `services/controlplane/internal/appliance/appliance.go`
- `services/controlplane/internal/config/config.go`
- `services/controlplane/internal/httpapi/serviceproxy.go`
- `services/controlplane/internal/serviceregistry/registry.go`
- tests under:
  - `services/controlplane/internal/appliance/`
  - `services/controlplane/internal/config/`
  - `services/controlplane/internal/httpapi/`

Phase 1 steps:

1. Introduce internal module descriptor types in the control-plane domain.
   Keep them close to the existing appliance capability/profile logic rather
   than creating a large new package tree.
2. Introduce an entitlement evaluator interface with a default
   always-true implementation.
3. Represent the current host-agent proxy exposure as a descriptor-backed
   platform module.
4. Add a resolution function that takes:
   - resolved profile/capabilities
   - entitlement evaluator
   - built-in module catalog
   and returns the enabled module set.
5. Keep the existing service-registry JSON contract intact for the first step,
   but generate the host-agent service proxy registration from the resolved
   module descriptor rather than hardcoded route declarations.
6. Keep control-plane route registration behavior unchanged by continuing to
   flow through the existing service-registry and service-proxy structures in
   the first pass.

Implementation rule:

- Phase 1 should not replace the service registry runtime model yet; it should
  feed it from descriptors.

Suggested tests:

- resolving current profiles still yields the same capability sets
- host-agent descriptor is enabled only when `host` capability is present
- entitlement=false suppresses the module cleanly
- generated service-registry/service-proxy output for host-agent matches the
  current route set exactly
- current host API proxy tests remain unchanged and green

### `appliance-ctl`: installer/product-config generation

Primary touchpoints:

- `internal/productconfig/productconfig.go`
- `internal/productconfig/productconfig_test.go`

Phase 1 steps:

1. Introduce the same logical concept on the installer side:
   - built-in module catalog
   - entitlement evaluator
   - resolution from profile/capability to enabled modules
2. Replace the hardcoded `serviceRegistry` host-agent block in
   `PrepareValuesFile` with descriptor-driven generation.
3. Keep the rendered values shape identical:
   - same `serviceRegistry` JSON/YAML structure
   - same host-agent backend URL
   - same route paths, methods, and permissions
4. Keep existing capability-based config toggles in place for now
   (`hostAgent.enabled`, DNS settings, artifact settings, build catalog, and so
   on). The first slice only needs the service proxy registration to come from
   descriptors.

Implementation rule:

- Phase 1 should not try to migrate every capability-controlled values block at
  once. Start with service-registry generation for host-agent only.

Suggested tests:

- rendered `serviceRegistry` for `core` and other host-capable profiles remains
  byte-equivalent or semantically equivalent to current output
- profiles without `host` capability still omit the registry block
- entitlement=false suppresses the host-agent registry entry
- existing product-config tests continue to pass

### Profile catalog staging

Primary touchpoints:

- `services/controlplane/internal/appliance/appliance.go`
- `internal/productconfig/productconfig.go`

Phase 1 steps:

1. Do not migrate profile catalogs to bundle metadata in the first coding
   slice.
2. Introduce a single internal abstraction for the curated profile catalog on
   each side, even if it still reads from code-backed tables.
3. Keep current profile names and capability combinations stable.

Implementation rule:

- profile catalog centralization is allowed in Phase 1; profile metadata
  externalization is not required in Phase 1.

### Verification and migration discipline

For each incremental code change:

1. keep the old hardcoded output as the behavioral reference
2. add descriptor-driven generation behind tests
3. compare generated host-agent route/service output against the current shape
4. only after equivalence is proven, remove redundant hardcoded host-agent
   blocks

Recommended execution order:

1. `appliance-code`: descriptor types, entitlement interface, host-agent module
   resolution, tests
2. `appliance-ctl`: descriptor-backed host-agent service-registry generation,
   tests
3. widen to other built-in modules only after host-agent equivalence is proven

### Explicit non-goals for Phase 1

Do not include these in the first implementation slice:

- runtime-added module installation
- runtime service self-registration of new public routes
- signed external module package handling
- operator-authored custom profiles
- full migration of every values/config toggle to module descriptors
- application-module onboarding flows

## Decisions Already Closed

These points are intentionally part of the plan:

- use descriptor-driven static composition now
- keep runtime-dynamic addition for a later phase
- use `entitlement`, not `license`
- entitlement starts as an always-true internal check
- control-plane API exposure remains centrally owned
- runtime services may report readiness but do not define new public routes
- profile catalogs should become metadata-driven
- profiles remain curated presets rather than user-authored extensibility

## Remaining Design Choices

The main items still needing concrete implementation decisions are:

- exact descriptor storage format in code and later in signed bundle metadata
- exact profile catalog storage format in code and later in signed bundle
  metadata
- where the canonical descriptor catalog lives across repos
- whether module dependencies are expressed only via capabilities or also via
  explicit module-to-module references
- how much of the runtime readiness handshake is needed in the first control
  plane iteration

Those choices should be resolved in implementation design, but none of them
change the overall rollout direction in this note.
