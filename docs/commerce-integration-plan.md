# Commerce Integration Plan

This plan brings the application functionality currently being developed in
`../capp` into the signed appliance product without importing the development
deployment workflow or weakening the air-gap contract.

## Scope

The first commerce slice contains:

- Ordering offerings and order creation/read APIs.
- An ordering-owned PostgreSQL schema in the appliance database.
- ForwardAuth integration with the existing control-plane identity/RBAC contract.
- The existing channel-integration adapter as a separate `ace-apps` workload.

The application mobile identity slice (OTP challenge, verification, and
sessions) is promoted as its own `application-identity` service. Operator
identity, tokens, and RBAC remain owned by the production control-plane
service. The remaining `capp` Core API domains (property, microzone, and
geocode administration) are follow-up contracts.

This slice does not yet claim to implement merchant administration, payments,
fulfillment, or a complete WhatsApp ordering conversation. Those remain later
application features built on the same APIs.

## Ownership

| Repository | Responsibility |
| --- | --- |
| `appliance-code` | Production Ordering source/image, schema, chart templates, catalog policy, and runtime tests |
| `appliance-ctl` | Signed-artifact resolution, image preload, secret preparation, Helm ordering, install/upgrade/verify behavior |
| `appliance-release` | Bundle orchestration, component inventory, cross-repository validation, and operator documentation |
| `capp` | Application-domain source/design upstream; its local/cloud development scripts are not product installer code |

The uncommitted `../capp` worktree remains untouched. Only reviewed runtime
source and contracts are promoted.

## Runtime layout

```text
ace-system
  controlplane

ace-infra
  platform-postgres
  blob-storage
  message-broker

ace-apps
  ui-server
  action-runtime
  channel-integration
  ordering
  application-identity
```

Ordering is an application service. It is not merged into the appliance
`controlplane` process. Its idempotent schema bootstrap runs at service startup
against the appliance PostgreSQL database; no second migration image is added
to the app-stack bundle. Existing profiles remain unchanged.

## Mandatory production-hardening gate

The remaining `capp` Core API remains a follow-up item. Its property, microzone,
and geocoder handlers are not part of this release. The promoted identity
slice retains only the local/test OTP inbox and private Unix socket; it refuses
production environments until a reviewed SMS/provider adapter and abuse
controls are implemented.

Ordering is gated on the existing ForwardAuth identity and permission contract.
The service accepts the trusted user identity headers emitted by Traefik and
does not accept a caller-supplied user ID or a capp session cookie.

## Delivery model

Keep the existing `application-core` profile; do not create another profile.
Add one capability named `commerce` with the signed `ordering`
image as its required artifact. The templates live in the existing appliance
control-plane chart so the release path remains one chart and one installer
contract.

The capability is included in the app-stack delivery pack and is activated only
by `application-core`. Do not reuse the existing `applications` capability;
that capability means host-agent-backed application management.

## Database and secret contract

Retain the appliance-owned `platform-postgres` pod for both local and EC2
installs. Add logical databases and purpose-separated roles while preserving
the existing control-plane database:

```text
controlplane       existing appliance control-plane data
  ordering_*         Ordering tables (isolated by table namespace for V1)
```

Ordering does not read control-plane identity tables. Its API receives the
authenticated user ID from ForwardAuth; merchant/Micro Zone administration and
membership checks remain a later capability.

Secrets are generated or supplied on the target and copied between namespaces
only through installer-owned, redacted operations. They must never enter the
bundle, Git, command arguments, or logs.

## Implementation phases

### Phase 1: Appliance-native application slice

- Reuse the existing control-plane identity, user, token, RBAC, and ForwardAuth
  contracts.
- Add the ordering service with trusted-header identity and idempotent schema
  bootstrap.
- Add ordering permissions and route policy to the control plane.

### Phase 2: Product source and charts

- Promote the reviewed Ordering source into `appliance-code`.
- Add fixed non-root identities, read-only root filesystems, and explicit
  writable paths.
- Add application-service chart templates.
- Map all development namespace/image names to `ace-system`, `ace-infra`,
  `ace-apps`, and `registry.local`.
- Keep the existing platform PostgreSQL deployment and isolate ordering tables
  under `ordering_*` names.

### Phase 3: Signed artifact contract

- Add `commerce` to the signed metadata catalogs.
- Add image/archive export targets and digest-pinned references.
- Extend release-input schema, verification, assembly, and image preload.
- Ensure profiles without the capability do not select or start these images.

### Phase 4: Installer and upgrade wiring

- Extend `appliance-ctl` artifact resolution and capability validation.
- Replicate the verified PostgreSQL connection Secret into `ace-apps` and wait
  for the ordering Deployment readiness.
- Preserve local/cloud parity: the signed bundle and Helm path remain the same;
  only target edge/TLS configuration differs.

### Phase 5: Verification

Run verification in every edited repository:

1. `make verify` in `appliance-code`.
2. `make verify` (or the repository’s full test target) in `appliance-ctl`.
3. `make verify` in `appliance-release`.
4. Render and test charts with capability enabled and disabled.
5. Fresh local `application-core` install, rerun, and upgrade.
6. Cloud EC2 install from a copied local bundle with target cleanup.
7. API smoke tests for ForwardAuth-protected offerings, idempotent order
   creation, and order retrieval.
8. Confirm profiles without `commerce` remain unchanged.

No real build server, publish server, or target host run is part of the code
change until these repository-local gates pass.

## Done gate

The feature is ready for a release run only when:

- The ordering image is present, signed, digest-pinned, and imported.
- PostgreSQL schema bootstrap and Secrets converge idempotently.
- `ordering` and `channel-integration` are healthy in `ace-apps`.
- Existing profiles and the air-gapped installation contract remain green.
