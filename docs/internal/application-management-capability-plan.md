# Application Management Capability Plan

## Purpose

Add a new Application Management capability to the existing Control Plane. The
capability allows an administrator or approved API client to install and manage
custom appliance applications supplied as a container image plus a declarative
application definition.

This is a new Control Plane responsibility. It is not a new Kubernetes service,
pod, chart, or standalone runtime.

The managed application itself runs as a separate Kubernetes workload. The
Control Plane remains the manager and reconciler for that workload.

## Explicit Boundary

Application Management and Automation Runtime are separate concerns.

Automation Runtime remains unchanged and continues to:

- execute the existing DSL-based automation definitions;
- parse and validate workflow inputs and outputs;
- call allowlisted appliance APIs;
- provide the existing metadata-bundle and automation contracts;
- remain independent of custom application containers.

This plan must not modify, rename, extend, or re-purpose Automation Runtime,
its workflow DSL, its workflow APIs, its metadata-bundle execution behavior, or
its Argo Workflows integration.

Argo Workflows remains limited to the developer/build workflow capability. The
Application Management capability must not submit application deployment work
through Argo or require the developer pack.

## Product Placement

Application Management is an always-enabled capability of the Control Plane.
It is included in the base/core profile and does not create a separate runtime
deployment.

```text
Control Plane pod
|- existing Control Plane APIs
|- existing Automation Runtime integration
`- Application Management capability
   |- application definitions and instances
   |- configuration and secrets
   |- Kubernetes reconciliation
   |- application lifecycle
   `- upgrade, rollback, backup, and restore integration
```

The Control Plane process owns the Application Management code and runs its
background reconciliation loop. The loop must be asynchronous and retry when
Kubernetes, storage, the local registry, or the message bus is temporarily
unavailable.

## Application Model

### Application Definition

An Application Definition is the immutable, versioned description of an
application. It declares:

- name, version, description, and compatibility;
- an immutable local image reference or digest;
- configuration schema and defaults;
- secret declarations without embedding secret values;
- CPU, memory, and other bounded resource requirements;
- service ports and health checks;
- persistent storage requirements;
- message-bus publications and subscriptions;
- explicitly permitted appliance API operations;
- upgrade and rollback compatibility;
- supported backup and restore behavior.

The initial implementation supports only a container application definition.
The definition must not contain arbitrary Kubernetes YAML.

### Application Instance

An Application Instance is the installed state of a definition. It contains:

- selected definition and image digest;
- desired lifecycle state;
- validated configuration values;
- references to protected secrets;
- runtime status and conditions;
- allocated storage and generated resource identities;
- operation and audit references;
- upgrade and rollback history.

Definitions and instances must be stored separately so that one definition can
be used by more than one installed instance in the future.

## Runtime Contract

The Control Plane Application Management code must:

1. Load and validate an application definition.
2. Verify that the image is available in the appliance's local registry or
   signed bundle and is digest-pinned.
3. Validate configuration against the definition schema.
4. Validate resource, storage, broker, and appliance API permissions.
5. Persist definition, instance, and desired state.
6. Generate only approved Kubernetes resources.
7. Reconcile resources asynchronously.
8. Retry failed or temporarily unavailable operations.
9. Report status and conditions through the Control Plane API.
10. Reconcile existing instances after Control Plane restart or upgrade.
11. Audit security-sensitive lifecycle and configuration operations.

Generated resources may include Deployments, Services, ConfigMaps, Secrets,
PVCs, ServiceAccounts, and NetworkPolicies. Resource generation must use typed,
allowlisted builders rather than accepting arbitrary manifests.

Application workloads must run outside `ace-system`, which is reserved for
core services. All managed application workloads use the permanently provisioned
`apps` namespace.

The `apps` namespace is created during installation and retained even when no
application has been installed. Application creation must not contain a
first-use namespace-creation path or depend on a race between the first API
request and namespace provisioning. Namespace creation, labels, Pod Security
configuration, resource policy, and baseline network policy are installation
concerns.

The namespace may contain a small platform-owned marker ConfigMap or equivalent
non-application definition if that makes ownership, diagnostics, backup, or
upgrade state explicit. It must not require a placeholder application workload.
The namespace must have explicit storage, network, UID/GID, and Pod Security
policy.

## Infrastructure Integration

### Message Bus

Applications may declare broker subjects. The Control Plane must provision or
reference application credentials, inject connection information, and enforce
publish/subscribe subject permissions. Applications must not receive broad
broker administrator access.

### Database and Storage

Applications must not mount the Control Plane SQLite database or receive its
database credentials. Application data uses application-owned PVCs or a future
explicit database service contract. Appliance-owned state is accessed through
authorized Control Plane APIs.

### Appliance APIs

Application API access is declared and allowlisted. Calls use service identity,
existing authorization rules, and audit logging. An application definition must
not be able to grant itself arbitrary Kubernetes or Control Plane privileges.

## Configuration Flow

```text
API or UI request
    -> schema and authorization validation
    -> persist instance configuration
    -> reconcile ConfigMap and Secret resources
    -> rolling application update
    -> report operation and health status
```

Configuration updates must be durable, retryable, auditable, and safe to repeat.
Secret values must never appear in Git, release artifacts, command arguments, or
ordinary logs.

## Lifecycle

### Install

- validate the definition and requested configuration;
- verify the local image and digest;
- verify permissions and resource limits;
- persist the instance;
- create resources through the reconciler;
- report accepted, progressing, ready, degraded, or failed state.

The request must not block until the application is ready.

### Upgrade

- validate the new definition and configuration compatibility;
- retain the current definition and image as rollback state;
- apply a controlled update;
- reconcile readiness and health;
- record success or restore the prior desired state on failure.

### Restart, Stop, and Remove

These operations must be idempotent and must preserve persistent data unless a
destructive data-removal option is explicitly requested.

### Appliance Upgrade

`zonctl` remains responsible for host and platform lifecycle: K3s, core charts,
release artifacts, transactions, and platform rollback. The Control Plane
preserves application definitions and instances, validates compatibility, and
reconciles managed workloads after the new Control Plane starts.

### Backup and Restore

The application-management state contract must cover:

- definitions and instances;
- desired lifecycle state;
- non-secret configuration;
- protected secret references or approved encrypted secret material;
- image digests and required artifact identity;
- application PVC data where supported;
- migration and compatibility metadata.

Restore must rehydrate durable state, verify required local artifacts, recreate
or reconnect storage, and reconcile workloads. Missing artifacts must produce a
visible degraded state; restore must not download from the public internet.

## API Scope

The initial API should be kept small and use the existing Control Plane
authentication, RBAC, audit, error, and operation conventions. The first API
contract needs only the operations required to:

- register or install an application definition;
- list and inspect applications;
- update validated instance configuration;
- request lifecycle operations;
- inspect status and conditions;
- upgrade or remove an application.

Separate registry, tool, domain, or workflow-specific APIs must not be added for
this capability unless an implementation requirement demonstrates the need.

## Repository Work Plan

### `appliance-code`

- Add Application Management as a clearly isolated modular-monolith area inside
  the existing Control Plane service. It shares the existing process, port,
  authentication, storage, and lifecycle, but must not be mixed into generic
  handlers or the Automation Runtime packages.
- Keep separable package boundaries for:
  - application definitions and schema validation;
  - application instances and lifecycle state;
  - application API handlers;
  - application persistence and migrations;
  - Kubernetes resource builders;
  - background reconciliation;
  - image and artifact verification;
  - broker and appliance API permission projection;
  - upgrade, rollback, backup, and restore coordination.
- Define narrow interfaces between these packages so the capability can be
  extracted into a separate service later without redesigning the application
  contract.
- Add Application Management domain models and persistence migrations.
- Add definition and configuration schema validation.
- Add application instance lifecycle state and operation tracking.
- Add typed Kubernetes resource builders and the background reconciler.
- Add local image and digest verification integration.
- Add broker identity and subject authorization integration.
- Add configuration, secret, storage, health, upgrade, rollback, and restore
  handling.
- Add Control Plane API handlers using existing auth, RBAC, audit, and error
  conventions.
- Add Control Plane startup reconciliation and interrupted-operation recovery.
- Add chart RBAC, permanent `apps` namespace provisioning, namespace labels,
  baseline NetworkPolicy, storage, and security-context configuration required
  by managed workloads.
- Add unit, API, reconciliation, restart, failure-retry, upgrade, rollback,
  backup, restore, and security tests.
- Do not change Automation Runtime packages, workflow DSL behavior, metadata
  automation execution, or Argo workflow behavior.

### `appliance-ctl`

- Add Application Management to the base/core capability set.
- Ensure the Control Plane is always installed with this capability enabled.
- Create the `apps` namespace during every fresh installation and upgrade path,
  before the Control Plane is considered ready for application management.
- Treat `apps` as an appliance-owned namespace even when it is empty.
- Preserve `apps` and its application data during normal upgrade and uninstall;
  remove it only through an explicit destructive data-loss operation.
- Add application workload and storage checks to diagnostics.
- Preserve application state and data across upgrade and normal uninstall.
- Make factory reset remove application data only under explicit data-loss and
  workspace/data wipe policy.
- Include application-management state in backup and restore orchestration.
- Add platform upgrade compatibility and post-upgrade reconciliation checks.
- Add recovery tests for interrupted install, upgrade, restore, and removal.
- Keep platform lifecycle ownership in `zonctl`; do not implement the application
  reconciler in the installer.

### `appliance-release`

- Add the always-enabled capability to the foundation/core release contract.
- Package application-definition schemas and a signed sample definition.
- Extend release-input and signed-bundle validation for application metadata.
- Ensure all required Control Plane chart configuration and permissions are
  bundled.
- Add new image inputs only through the shared online/offline dependency path.
- Require local, digest-pinned application image identity for air-gapped use.
- Update component catalog, deployment, operator, upgrade, backup, and restore
  documentation.
- Add cross-repository checks covering:

```text
definition -> release-input -> signed bundle -> zonctl verification/import
  -> Control Plane chart/configuration -> permanent apps namespace
  -> Application Management
-> local image resolution -> managed workload
```

## Non-Goals

The first implementation will not add:

- a separate Application Runtime service or pod;
- changes to Automation Runtime or its DSL;
- Argo as an application-runtime dependency;
- Helm application support;
- raw Kubernetes manifest deployment;
- KubeVela or another application platform dependency;
- marketplace or catalog synchronization;
- arbitrary host mounts or privileged containers;
- arbitrary RBAC or unrestricted broker access;
- public-registry pulls;
- application script execution;
- complex dependency graphs between applications;
- a large API surface before the lifecycle contract is proven.

## Completion Criteria

The plan is complete when:

- Application Management is an always-enabled Control Plane capability.
- The `apps` namespace exists before the first application-management request.
- Application Management code is modular inside the Control Plane modular
  monolith and has narrow separable package boundaries.
- Automation Runtime behavior and code boundaries are unchanged.
- A signed, digest-pinned container definition can be installed and reconciled.
- Configuration, secrets, broker access, storage, health, and permissions are
  enforced.
- Control Plane restart and platform upgrade recover application state.
- Application upgrade and rollback are durable and auditable.
- Backup and restore preserve or explicitly report application state.
- All three repositories pass their mandatory verification gates.
- The complete offline release path is tested end to end.
