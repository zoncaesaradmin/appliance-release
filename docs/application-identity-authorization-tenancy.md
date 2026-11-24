# Application identity, authorization, and tenancy model

This document records the application-level identity and authorization model
for customer, vendor, channel, zone, and tenant workflows. It extends the
current mobile identity and commerce slices; it does not replace operator
authentication, operator RBAC, or the appliance control-plane identity.

## Status and execution boundary

This is the approved target model for future application APIs, entrypoints,
and channel integrations. The first executable identity slice is now present:
the application identity service has a fixed `zonited-solutions` tenant for
the current operating company, server-side
channel policies, keyed channel-subject mappings, channel-bound short-lived
sessions, and an authenticated internal principal-resolution contract. The
channel integration has an opt-in client for that contract, while memberships,
tenant administration, and application authorization enforcement remain future
work.

The model is intentionally generic before implementation. It defines the
stable nouns and enforcement points that new services must use, without
requiring every customer, vendor, zone, or tenant workflow to be built in the
first slice.

## Non-negotiable invariants

1. Application identity is separate from appliance operator identity. An
   application user can never acquire appliance-console authority through a
   customer, vendor, web, or WhatsApp session.
2. A raw phone number, WhatsApp sender value, HTTP header supplied by a
   caller, UI route, or channel name is never an authorization grant.
3. Every privileged action is evaluated server-side against tenant, role,
   service, and zone scope. Hiding a UI control is not enforcement.
4. A user may exist and receive general application access without a zone,
   vendor, or tenant-administration membership.
5. A channel adapter translates provider data into a generic principal. No
   application domain API depends on Meta/WhatsApp payload fields.
6. A role is always scoped. In particular, zone administrator, vendor, and
   tenant administrator are not global roles.
7. Session credentials are transport-specific and revocable. A browser cookie
   must not be repurposed as a long-lived credential held by a channel adapter.

## Entry-point access matrix

| Entry point | Initial proof | First-use result | Access before approval or zone selection | Privileged access gate |
| --- | --- | --- | --- | --- |
| Customer web | Phone OTP | Identified application user and `customer-web` session | General discovery, city/group rental views, public/read APIs | Active customer-zone membership for zone services; scoped zone-admin grant for administration |
| Customer WhatsApp | Valid provider-signed message to a configured customer endpoint | Identified application user and server-side `customer-whatsapp` interaction session | Same general discovery/read access and zone-joining conversation | Active customer-zone membership for zone services |
| Vendor web | Registration link, approved invitation, or another reviewed onboarding proof | Vendor prospect or registered applicant and `vendor-web` session | Business preview, registration status, permitted onboarding actions | Approved vendor-zone/service assignment |
| Vendor WhatsApp | Valid provider-signed message to a configured vendor endpoint | Vendor prospect or existing vendor-channel subject | Business preview and registration guidance only | Existing approved vendor-zone/service assignment |
| Zone administration web | Authenticated application user in an explicit zone-admin entrypoint | Normal application session with an administrator audience | No elevated rights merely from the URL | Scoped zone-admin grant for the selected tenant and zone |
| Appliance console | Operator login only | Operator session | Appliance operations only | Existing operator RBAC; never application memberships |

The customer and vendor web entrypoints may eventually have distinct paths and
PWA shells, but their path is an audience selection, not a permission grant.

## Design decision

An application user is not required to belong to a zone before receiving
useful access. Zone membership is an additional authorization grant, not the
definition of the user.

The platform must support all of these at the same time:

- A general identified user with no zone membership.
- A customer with memberships in one or more zones.
- A customer who is also an administrator or operator for a particular zone.
- A vendor who serves different services in different zones.
- A user with different roles, scopes, or memberships across tenants and zones.
- A vendor prospect who can see a limited business view before approval.

Do not encode any of these states in a phone number, a single global role, or
the name of a channel.

## Core terms

### Application user

An application user is a durable, opaque `application_user_id`. The identity
store may use a verified phone number as one login attribute, but the phone
number is not an authorization key and is not a substitute for the user ID.

The same user may be a customer in one zone and a vendor representative in
another zone.

### Channel

A channel is an application entrypoint or communication endpoint. Examples:

- `customer-web`
- `vendor-web`
- `customer-whatsapp-main`
- `vendor-whatsapp-main`

For WhatsApp, `channel_id` identifies the configured platform receiving number
(the Meta `phone_number_id` is mapped to a stable product channel ID). The
sender's WhatsApp identifier is a separate channel subject. For web, the
entrypoint and profile select the channel.

Provider-specific concepts remain inside `channel-integration`. Common APIs
receive only the stable channel ID and generic principal fields.

### Channel subject

A channel subject is the external identity observed on one channel, such as a
WhatsApp sender ID or a browser-authenticated subject. It is mapped explicitly
to an application user:

```text
(channel_id, external_subject_id) -> application_user_id
```

The mapping must not be inferred from an unverified phone string alone.

### Zone

A zone is a managed service area (the product may display a branded name for
it). A user can have no zone membership, one membership, or many memberships.
All zone-scoped access must check the requested `zone_id` against the user's
grants.

### Tenant

A tenant is the top-level authority and isolation boundary for application
configuration, policies, managed zones, and tenant-scoped memberships. It is
not synonymous with a user, vendor, channel, or zone.

The first release has one explicit operating-company tenant:
`zonited-solutions`, displayed as `Zonited Solutions`. This identifies the
organization currently managing the application policies and services. Do not
omit `tenant_id` merely because there is only one tenant today.

Future deployments may distinguish:

- the tenant that manages a zone;
- the tenant that hosts the service or infrastructure; and
- a vendor or other business that participates in the zone.

Those relationships must be modeled explicitly rather than treating every
vendor or host as the tenant.

### Tenant, zone, vendor, and service relationship

The default topology is deliberately simple:

```text
Zonited Solutions operating-company tenant
  -> manages every initial zone
  -> owns the default policy and channel configuration
```

The data model must nevertheless permit a future topology such as:

```text
managing tenant
  -> manages zone
hosting tenant
  -> hosts the zone's application deployment
vendor organization
  -> is approved to offer specific services in that zone
```

Tenant, zone, vendor organization, service, and user are independent opaque
entities. A vendor organization can participate in more than one tenant and
zone only when explicit assignments allow it. A user can represent a vendor
organization in one zone and be an ordinary customer in another.

### Stable IDs and uniqueness

Use generated opaque IDs for `application_user_id`, `tenant_id`, `zone_id`,
`vendor_organization_id`, `service_id`, `channel_id`, and `session_id`.

- A verified phone remains a useful login identity, but it is not the primary
  authorization key.
- A channel subject is unique within its provider/channel namespace, not
  globally by a raw display string.
- A WhatsApp endpoint may rotate its provider number or ID while retaining its
  stable product `channel_id`.
- The same phone may be associated with one application user that has many
  memberships. Do not infer a membership or merge independent accounts solely
  from matching phone text; explicit linking and conflict handling are needed.

## Identity and membership state

There is no single global `valid_user` flag. Use separate state machines.

```text
application_user
  registered | suspended

channel_subject
  pending | linked | blocked

customer_zone_membership
  pending | active | revoked

vendor_registration
  prospect | registered | rejected

vendor_zone_membership
  pending | approved | suspended | revoked
```

An identified user with no zone membership can still receive general access.
For example, a customer may read city-wide or group-wide rental discovery APIs
before choosing a zone. A vendor prospect may read the business-facing
registration and service information without being able to manage inventory,
orders, or fulfillment.

“Onboarded” is derived from the relevant active or approved membership:

- customer onboarded: at least one active customer-zone membership;
- vendor onboarded: at least one approved vendor-zone membership.

These state names are deliberately domain-neutral and do not use product
branding.

## Roles and scopes

Roles are always scoped to the authority where they are meaningful.

Examples include:

- general application user: discovery and read-only application APIs;
- customer: customer services for permitted zones;
- zone administrator: customer-side administration for one zone;
- zone operator: internal operational actions for one zone;
- vendor representative: vendor actions for explicitly assigned zones;
- tenant administrator: tenant-wide administration;
- vendor prospect: registration and business-preview APIs only.

A zone administrator is a customer-domain privilege scoped to a specific
`tenant_id` and `zone_id`; it is not a global operator role. A vendor may have
different service permissions in different zones, so vendor grants should be
represented as scoped memberships or assignments, for example:

```text
vendor_user -> tenant-A -> zone-1 -> service-catalog.manage
vendor_user -> tenant-A -> zone-2 -> order-fulfillment.read
```

The effective principal for a request is resolved from:

```text
application user
  + channel policy
  + tenant context
  + role/membership grants
  + requested zone and service scope
```

Channel selection can constrain an audience, but a channel alone must never
grant vendor, zone-admin, or tenant-admin privileges.

### Permission evaluation

Authorization should be deny-by-default and evaluate a request in this order:

```text
1. Resolve and validate the session/interaction principal.
2. Resolve the channel policy and allowed audience.
3. Resolve the tenant implied by the requested resource or explicit context.
4. Resolve active memberships and scoped role assignments.
5. Check the requested service, action, and zone scope.
6. Record an auditable allow or deny decision for sensitive actions.
```

The effective permission set is an intersection, not a union of every role a
person has elsewhere:

```text
effective permission
  = application permission
  ∩ channel audience policy
  ∩ tenant policy
  ∩ active role/membership
  ∩ requested zone/service scope
```

For example, a user who is a zone administrator for `zone-A` cannot use that
grant to administer `zone-B`, and a vendor approved for a delivery service in
one zone cannot automatically manage catalog data in another.

### General access versus membership access

General access is a real authorization tier, not an accidental fallback.

| Tier | Typical examples | Does it require zone membership? |
| --- | --- | --- |
| Public | Marketing, publicly visible zone discovery | No identity required when policy allows |
| Identified | Saved preferences, city/group rental discovery, non-sensitive read APIs | No |
| Customer member | Zone services, customer orders, resident/member resources | Active customer-zone membership |
| Zone administrator/operator | Zone administration and internal operations | Scoped role assignment in that zone |
| Vendor prospect | Registration guidance, business preview, application status | No approved vendor membership |
| Approved vendor | Service, catalog, fulfillment, or operational APIs | Scoped vendor-zone/service assignment |
| Tenant administrator | Tenant policy and cross-zone administration | Scoped tenant role |

An API must declare which tier it serves. “General” APIs must still apply
tenant visibility policy and prevent enumeration of private tenants, zones,
vendors, addresses, or user data.

## First-use workflows

### Customer WhatsApp

The signed Meta webhook is the initial channel proof; a second OTP is not
required for ordinary first contact.

```text
valid webhook
  -> resolve or create application user
  -> create/refresh customer-channel session
  -> grant general customer discovery access
  -> optionally start zone discovery and joining
```

The user may send a location, receive nearby zones, select a zone, and then
receive an active customer-zone membership. Until then, the session remains a
general identified-user session.

### Customer web

The web entrypoint uses phone OTP to establish the initial application
identity, then enters the same general-user and optional zone-joining flow.

### Vendor web or offline onboarding

Vendor registration is not granted by a first message. A registration link,
offline process, or administrator workflow creates a vendor prospect or
registered vendor record. Approval then creates vendor-zone memberships with
explicit service scopes.

### Vendor WhatsApp

The vendor channel can expose a limited business preview and registration
guidance to an unknown sender. Operational vendor APIs require an existing
approved vendor membership for the requested tenant and zone.

### Identity linking and account recovery

The product must distinguish “a channel sender was seen” from “two entrypoints
belong to the same person.” A customer who first contacts a WhatsApp channel
and later signs in on the web should be linked through an explicit verified
flow, not by silently trusting a matching unnormalized phone field.

The initial policy is:

- A valid customer WhatsApp webhook may create a low-privilege identified user
  and customer-channel subject without a second OTP.
- A web login uses OTP because the browser has no provider-authenticated
  sender identity.
- A successful web verification may propose linking to an existing channel
  subject only after verified normalized identity comparison and conflict
  checks.
- A collision, a shared number, a changed number, or an existing different
  account enters a recovery/link-review workflow. It must never merge two
  accounts automatically.
- Sensitive changes, such as changing the verified phone or adding a privileged
  channel subject, require step-up verification and audit logging.

Sending an OTP back to the same WhatsApp account that just sent a signed
message is not an independent factor. It may be used for interaction design or
link confirmation, but not presented as stronger authentication.

### Location and zone discovery

Location is an onboarding input, not an authorization claim. A user may share
a current location, search manually, or choose another area. The system can
return nearby zones and let the user request or select a membership, but it
must not grant zone access simply because a device reports a coordinate.

Location data requires an explicit retention and precision policy. General
discovery should use the minimum precision needed, and channel logs, audit
events, analytics, and support bundles must not unnecessarily retain raw
coordinates or message content.

## Sessions and API principals

Web and channel sessions use the same application identity subsystem but do not
need to share the same raw credential.

- Web uses the secure application session cookie.
- WhatsApp uses a server-side channel session or short-lived internal
  assertion; no browser cookie is involved.

Both resolve to a common principal shape:

```text
application_user_id
session_id
channel_id
tenant_id (when selected or required)
roles
permissions
zone_scopes
authentication_method
```

Application APIs and services must consume this generic principal. They must
not parse WhatsApp payloads or know Meta-specific identifiers.

### Session and interaction rules

- Browser sessions are opaque, `HttpOnly`, `Secure`, same-origin credentials;
  JavaScript must not receive their raw value.
- Channel interactions use a server-side session or short-lived internal
  assertion bound to the channel adapter. Raw long-lived application session
  credentials must not be stored in provider payloads, chat histories, or
  channel configuration.
- A session is bound to its channel/audience. Reusing a customer-web session
  as vendor-web or zone-admin authority requires a separate policy evaluation,
  not a client-side route change.
- Membership approval, suspension, role removal, channel-subject blocking,
  account suspension, and tenant deactivation take effect on the next
  authorization check. Sessions therefore require introspection or a bounded
  revocation/version mechanism; long-lived unrevocable claims are not enough.
- Session issuance, linking, elevation, approval, revocation, and sensitive
  failures are auditable. Ordinary message text, OTP values, cookies, and raw
  credential material are never written to audit events or logs.
- Provider retries and duplicate inbound messages are expected. Channel
  interactions require idempotency keys and replay protection before invoking
  mutating application APIs.

### Trusted principal transport

Application services receive principal context only from a trusted gateway or
internal service credential. Public callers must not be able to supply or
override headers such as user, channel, tenant, zone, role, or permission.

The common transport may use signed internal assertions or gateway-injected
headers, but it must carry at least the authenticated user, session or
interaction ID, channel ID, authorization method, tenant context when known,
and scoped grants. Services must reject a missing, malformed, expired, or
untrusted principal context.

## Storage boundaries

The exact physical database layout may evolve, but ownership should remain
clear:

- identity store: users, phone identities, channel subjects, sessions, and
  identity state;
- customer/commerce store: customer onboarding and zone memberships;
- vendor store: vendor registration, approval, organization membership, and
  vendor-zone/service assignments;
- ordering store: offerings, orders, and transaction state.

These stores share opaque IDs such as `application_user_id`, `tenant_id`, and
`zone_id`. They should not use phone numbers as cross-service foreign keys.

## Channel endpoint governance

Channel endpoints are tenant-controlled configuration, not user-created
metadata. Each endpoint records, at minimum:

```text
channel_id
tenant_id
audience                 customer | vendor | administration | other approved audience
provider binding         kept inside the adapter configuration
enabled/disabled state
allowed onboarding mode
default general-access policy
```

The channel adapter maps a provider endpoint to this record before resolving a
sender. Unknown, disabled, misrouted, or tenant-mismatched provider endpoints
must fail closed. Rotating a WhatsApp number or provider identifier updates the
adapter mapping; it does not change historical application user, membership,
or order identities.

One endpoint must not be allowed to claim another tenant's channel ID. A
tenant's customer and vendor endpoints may have different onboarding and
permission policies even when they use the same provider.

## Tenant isolation, visibility, and context selection

The initial Zonited Solutions operating-company tenant is a real
row/configuration record, not an implicit absence of tenancy. Every
tenant-owned resource carries a tenant ID.

- A general user may see only tenant-approved public or discovery data.
- A user with memberships in multiple tenants must select, or have a request
  derive, one tenant context; APIs must not aggregate private data across
  tenants by default.
- A zone ID is resolved under its tenant. A caller cannot substitute a zone ID
  from another tenant into an otherwise valid request.
- Search, suggestions, counts, error messages, and pagination must not reveal
  the existence of private tenants, zones, vendors, or memberships.
- Tenant deletion, suspension, ownership transfer, or hosting migration must
  revoke or re-evaluate dependent memberships and sessions predictably.

The tenant context may be absent for truly global/public discovery, but then
the API explicitly applies the global visibility policy rather than treating
absence as unrestricted access.

## Organizations, delegation, and approval

A vendor organization is not a user account. It can have multiple
representatives, each with independently revocable assignments. Removing one
representative removes that person's access without deleting the vendor,
services, historical orders, or other representatives.

Every privileged assignment records at least:

```text
subject type and ID
role/service grant
tenant and optional zone scope
issuer/approver
effective time and expiry when applicable
state and revocation reason
```

Default delegation rules:

- A zone administrator can manage only the delegated zone and cannot create
  tenant administrators or grant authority in another zone.
- A vendor representative cannot approve their own vendor organization or
  expand its zone/service scope.
- Vendor approval and zone/service assignment are tenant-controlled actions.
- Tenant administrators can delegate only permissions within their tenant.
- A suspended user, organization, tenant, or zone overrides otherwise active
  grants.

The product may later require dual approval, regulated onboarding, expiry, or
separation-of-duties policies. The generic grant record must allow those
policies without redefining the user or channel model.

## Channel and conversation safety

Channel-specific authentication establishes the origin of an interaction, not
unlimited permission. For provider-backed messaging channels:

- verify the provider signature before parsing or acting on a payload;
- bind the request to a configured, enabled endpoint before resolving a
  sender;
- deduplicate provider event IDs and use idempotency for downstream mutations;
- retain only the minimum message metadata/content necessary for the workflow;
- respect provider opt-in, template, rate-limit, and outbound-message policy;
- never place session credentials, privileged links, secrets, or sensitive
  data in chat messages; and
- treat natural-language commands, future automation output, and location
  claims as untrusted input subject to the same authorization check as a web
  request.

Conversation IDs can provide continuity and correlation, but they are not a
user, a role, or proof that a later message has the same authority.

## Policy evolution and migration

Roles, permissions, channel policies, and membership state machines will grow.
They must be versioned and migrated deliberately:

- New permissions start denied until an explicit grant/policy enables them.
- A changed role definition must trigger authorization re-evaluation; an old
  cached session cannot retain removed access indefinitely.
- Tenant/channel/zone migrations preserve opaque IDs and audit history even if
  display names, provider bindings, or hosting arrangements change.
- Import, backup, restore, and tenant migration exclude raw session and OTP
  credentials by default, while preserving only reviewed identity and desired
  policy data according to lifecycle policy.

## Current implementation gaps

The current application identity service now provides phone OTP plus the first
generic principal foundation, but it does not yet provide:

- customer-zone or vendor-zone memberships;
- vendor approval state;
- application-session support in the existing ForwardAuth path; or
- downstream application-service calls that enforce the resolved principal.

The channel adapter currently verifies Meta webhooks, resolves an optional
generic principal, and sends replies. The next implementation must connect
that principal to application-service gateways without leaking WhatsApp
concepts into ordering, customer, vendor, or other application APIs.

## Execution plan

### Phase 0: Contract and policy freeze

- Publish the generic nouns in this document in the API/schema design:
  application user, channel endpoint, channel subject, tenant, zone,
  membership, role assignment, service assignment, session, and principal.
- Define the initial fixed `zonited-solutions` tenant and its default policies.
- Define the first customer, vendor, zone-admin, and tenant-admin permission
  names, including the general read/discovery tier.
- Decide visibility, retention, consent, and manual-review defaults before
  storing location, channel identities, or onboarding data.

### Phase 1: Generic application identity foundation

Status: initial slice implemented; adapter/gateway integration is still pending.

- Evolve the application identity schema from phone-only users and
  user-only sessions to opaque application users, channel subjects, and
  channel-bound sessions.
- Add explicit linking, blocking, session revocation, account recovery, and
  audit behavior. The initial slice implements keyed subject linking,
  blocking-state checks, and revocable channel sessions; account recovery and
  audit views remain follow-on work.
- Preserve the current OTP flow as one web authentication adapter; do not
  turn the existing operator JWT/API-token model into the application model.
- Expose an internal, authenticated principal-resolution contract for trusted
  channel adapters and gateways.

### Phase 2: Tenant, zone, and role grants

- Add tenant, zone, customer membership, vendor organization, vendor-zone
  assignment, and scoped role-assignment records with clear service ownership.
- Seed the explicit Zonited Solutions tenant and permit general users with no
  zone membership.
- Implement server-side scope checks and explainable deny reasons without
  exposing private resource existence.

### Phase 3: Gateway and application API integration

- Extend the application authorization path so browser sessions and trusted
  channel interactions become the same generic principal at application APIs.
- Keep operator ForwardAuth behavior isolated; application principal support
  must not weaken operator routes.
- Pass trusted user, channel, tenant, zone scope, correlation, and
  idempotency context to ordering and later application services.
- Make ordering and every new application API enforce its declared access tier.

### Phase 4: Entry points and onboarding

- Implement customer web, customer WhatsApp, vendor web, and vendor WhatsApp
  entrypoint policy using stable channel IDs.
- Implement general discovery before zone membership, zone discovery and
  joining, vendor prospect registration, approval, and zone/service assignment.
- Add separate UX shells or routes where helpful, but derive privileges from
  principal grants rather than the route.

### Phase 5: Operations and lifecycle

- Provide tenant/channel/role/membership administration APIs for authorized
  tenant or zone administrators.
- Add audit views, revocation, subject blocking, endpoint rotation, account
  recovery, data retention/erasure, and migration behavior.
- Test one-to-many and many-to-many cases: one user across channels, zones,
  vendors, and tenants; one vendor across services and zones; and account-link
  conflict/review cases.

## Required verification matrix

Before enabling a privileged application workflow, automated tests must cover:

| Scenario | Required outcome |
| --- | --- |
| New customer WhatsApp sender | General identified-user access only; no implicit zone membership |
| New customer web OTP user | Same general-access tier as customer WhatsApp |
| Location submitted by user | Zone suggestions only; no automatic authorization grant |
| Customer joins one zone | Access only to that zone's customer services |
| Same user is zone admin in one zone | Administration succeeds only in that zone |
| Same user is vendor in another zone | Vendor permissions work only for approved service/zone assignments |
| Unknown vendor WhatsApp sender | Business preview only; no vendor operational API access |
| Vendor removed/suspended | Existing sessions lose protected access on next check |
| Cross-tenant zone substitution | Rejected without leaking private-resource existence |
| Replayed webhook or duplicate message | No duplicate order, membership, or side effect |
| Channel endpoint rotation | Existing product channel ID and history remain stable |
| Phone/account-link collision | No automatic merge; recovery/review flow required |
| Operator credential on application endpoint | Rejected unless an explicit application policy allows it |
| Application credential on console endpoint | Rejected |

## Ready-to-execute gate

The plan is ready for implementation when each new slice preserves the
invariants above and introduces only the generic primitives it needs. The
first executable slice should be the generic identity foundation and trusted
principal contract, not a WhatsApp-specific direct call to ordering.

It is acceptable to defer richer customer, vendor, and zone UI flows, but it
is not acceptable to bypass tenant/channel/scope checks with a temporary
phone-to-user shortcut. That shortcut would become the major migration gap this
plan is designed to avoid.

## Implementation constraints

1. Keep operator authentication and operator RBAC separate from application
   identity and application roles.
2. Do not use a phone number as a role, tenant, zone, or vendor key.
3. Do not auto-grant vendor or zone-admin privileges from a channel message.
4. Enforce tenant and zone scopes server-side; UI visibility is not a security
   boundary.
5. Preserve general identified-user access even when no zone membership exists.
6. Treat channel adapters as translators into the generic principal contract.
7. Keep the initial Zonited Solutions operating-company tenant explicit so
   multi-tenant expansion does not require a data-model rewrite.
8. Make approval, suspension, transfer, and removal decisions effective in
   authorization without waiting for a long-lived client claim to expire.
9. Treat location, phone identities, message metadata, and onboarding evidence
   as sensitive data with an explicit retention, export, and erasure policy.
10. Design every mutating channel workflow for provider retries and idempotency.

## First onboarding slice implemented

The first end-to-end customer slice now follows the model above:

1. A web user signs in with the application OTP flow. A WhatsApp user is
   resolved by the trusted channel adapter; the provider sender remains outside
   the application API.
2. The identity service creates a short-lived, opaque discovery link for a
   channel interaction. The link is bound to the tenant, channel, audience,
   and application user; it does not contain a phone number or provider ID.
3. `/app/discover` requests browser location permission and posts latitude and
   longitude to the shared onboarding API. The API caps the search to 10 km,
   returns at most five active public zones, and calculates distance on the
   server.
4. The user must have an application session before submitting a pending join
   request. No membership, vendor privilege, zone-admin role, or service
   permission is granted by discovery. Approval remains an explicit later
   operation.

If no nearby zone exists, the signed-in user can submit a named Zonity creation
request. This records a request for tenant/platform review only. There is no
end-user zone-creation API: tenant-authorized platform staff create the Zonity
and then send confirmation through a later administrative workflow.

The nearby discovery endpoint accepts either the application session cookie
(web) or the short-lived discovery token (WhatsApp link). Joining and requesting
a new Zonity require the application session, even when the flow started from
WhatsApp. The current WhatsApp adapter also recognizes location messages, but
the browser link is still the authoritative location submission path; provider
location payloads are not trusted as an authorization grant. Zone catalog administration,
approval/rejection UI, confirmation delivery, real SMS delivery, vendor
onboarding, and provider retry/idempotency persistence remain follow-up work.
