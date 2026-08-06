# Control Plane UI SPA Plan

## Purpose

This document captures the execution-ready migration plan for replacing the
legacy HTMX-based appliance UI with a React + TypeScript single-page
application.

The new implementation will:

- live at `appliance-code/services/controlplane-ui`
- remove `appliance-code/services/ui` entirely
- call only the control-plane OpenAPI surface from the browser
- preserve the appliance packaging model where the UI remains a separate
  bundled service/runtime artifact
- support both production appliance deployment and local developer workflows

This document intentionally covers planning, architecture, workflow, packaging,
testing, and UI/UX constraints. It is not the implementation checklist itself.

## Execution Status

Current implementation status:

- `appliance-code/services/ui` has been replaced by
  `appliance-code/services/controlplane-ui`.
- The new service is a React + TypeScript SPA served by a Go static host.
- The browser client uses the control-plane OpenAPI routes directly under
  `/api/v1` plus existing `/version` and health routes.
- Local mock mode and real-appliance proxy mode are documented in the UI
  service README.
- The UI service verification gate now builds the SPA, compiles the Go host,
  typechecks TypeScript, checks generated OpenAPI types, runs Vitest/jsdom
  browser-side tests, and runs Go tests.
- The browser-side tests cover auth storage, direct API-client refresh/error
  behavior, mock control-plane behavior, and navigation rules.
- The Go static-host tests cover SPA fallback, API path refusal, method
  rejection, readiness failure, missing-bundle failure, immutable asset
  caching, and security headers.
- The UI image build accepts configurable Node, Go, and runtime base images so
  release jobs can inject mirrored or digest-pinned references.
- UI regression is covered by `make verify` in
  `appliance-code/services/controlplane-ui`.
- `development-container` now includes pinned Node.js and npm for UI builds.
- `appliance-ctl` does not require code changes while the released
  image/archive contract remains `appliance-ui`.

Validated local gates:

- `make verify` in `appliance-code`
- `make verify` in `appliance-release`
- `make verify` in `appliance-ctl`

Still external or future-backend dependent:

- Linux Buildah/Podman image/archive build must run on the build server or a
  Linux dev-container host.
- Notifications/alarms, detailed admin service metrics, support-bundle,
  licensing, and richer workflow analytics need backend APIs before the UI can
  become fully functional in those areas.

## Key Decisions

- Use `services/controlplane-ui` as the new source path to keep git history
  clean and separate the new SPA from the removed server-rendered UI.
- Treat the existing `services/ui` implementation as disposable.
- Keep the functional scope unchanged for now: the new UI should expose the
  same product capabilities the current UI exposes.
- Use the control-plane OpenAPI document as the complete browser contract.
- Use a direct browser SPA model instead of a server-side UI session layer.
- Support three developer modes:
  - fully local UI with a mocked control plane
  - local UI against a local real control plane
  - local UI against a remote appliance
- Keep production traffic same-origin. For local development, use a frontend
  dev proxy instead of widening product CORS behavior by default.

## Current UI Scope To Preserve

The SPA must cover the current browser feature surface:

- initial setup status and first-admin creation
- login, session refresh, logout, and current-session display
- appliance identity and capability-aware navigation
- dashboard status and summary panels
- API token management
- builder Git access configuration
- workspace profile listing
- workspace creation, selection, deletion, and current workspace display
- build target listing, build submission, and latest build status
- registry repository browsing
- registry tags and referrers inspection
- registry grant administration
- DNS record listing, creation, update, and deletion

No new product functionality is required in this migration unless needed to
support the UI architecture itself, such as OpenAPI completion, mock support,
or browser-safe auth handling.

## Milestone Plan

### Milestone 1: Contract Freeze

#### Goal

Lock the migration boundary and repo responsibilities before implementation
starts.

#### Deliverables

- confirm `appliance-code/services/controlplane-ui` as the new UI source path
- confirm `appliance-code/services/ui` will be removed
- confirm the browser will use only control-plane APIs
- confirm the UI remains a separate packaged service in the appliance release
- record cross-repo impact across `appliance-code`, `appliance-release`,
  `appliance-ctl`, and `development-container`

#### Validation Gate

- one written migration brief exists
- all repos know whether they own source, packaging, install, or toolchain
  work
- no ambiguity remains about whether HTMX compatibility is required

### Milestone 2: UI Surface Audit

#### Goal

Inventory every current UI feature that must be represented in the SPA.

#### Deliverables

- map current UI capabilities to real control-plane handler routes
- identify any current UI behavior that depends on the old server-side UI layer
- produce the canonical browser feature list used by OpenAPI and frontend work

#### Validation Gate

- every retained browser feature maps to a real control-plane route
- any missing API/spec coverage is explicitly listed

### Milestone 3: OpenAPI Completion

#### Goal

Make the OpenAPI spec the full contract for the browser UI.

#### Deliverables

- complete `appliance-code/docs/openapi/control-plane-v1.yaml` for:
  - setup
  - auth
  - capabilities
  - appliance identity
  - tokens
  - builder Git access
  - work profiles
  - workspaces and current workspace
  - build targets, build submission, and build status
  - registry repositories, tags, referrers, and grants
  - DNS records
- align response bodies, validation failures, and auth errors with actual
  control-plane handler behavior
- validate the spec against implemented handlers

#### Validation Gate

- no SPA-required endpoint is missing from the OpenAPI spec
- the spec is strong enough to drive a generated TypeScript client without
  manual endpoint wrappers

### Milestone 4: Browser Auth and Runtime Architecture

#### Goal

Define the highest-risk runtime behavior before frontend implementation begins.

#### Deliverables

- login flow for direct SPA use
- access-token refresh strategy
- logout behavior
- protected-route behavior
- invalid-session recovery behavior
- expired-session behavior
- same-origin production behavior
- local-dev proxy behavior
- runtime configuration model for:
  - mock mode
  - local real-control-plane mode
  - remote appliance mode

#### Validation Gate

- auth flow is documented clearly enough for implementation
- no unresolved question remains about how the browser obtains, refreshes, and
  clears credentials

### Milestone 5: Frontend Workspace Architecture

#### Goal

Define the new UI project structure before scaffolding code.

#### Deliverables

- React + TypeScript SPA under `appliance-code/services/controlplane-ui`
- Vite-based local development workflow
- generated TypeScript client from the control-plane OpenAPI spec
- application route structure
- shared layout and navigation shell
- runtime config and environment handling
- production static asset serving approach

#### Validation Gate

- the app structure is stable enough to scaffold without rework
- the team agrees on React + TypeScript + Vite as the frontend baseline

### Milestone 6: Local Developer Workflow

#### Goal

Make the new UI practical to build on developer laptops and workstations.

#### Deliverables

- commands for local install, run, lint, test, and build
- support for:
  - local mock mode
  - local real-control-plane mode
  - remote appliance mode
- frontend dev server proxy strategy
- basic contributor workflow documentation for macOS/Linux development

#### Validation Gate

- a developer can work on the UI without needing a live appliance at all times
- a developer can also point the UI at a real appliance when needed

### Milestone 7: Mock Control Plane and Fixtures

#### Goal

Support fast local UI iteration with realistic appliance behavior.

#### Deliverables

- local mock control-plane implementation or mock adapter layer
- realistic fixture states for:
  - logged-out and logged-in sessions
  - setup required versus initialized
  - different capability combinations
  - ready and pending workspaces
  - build targets and build states
  - registry repository/tag/referrer states
  - registry grants
  - DNS record states

#### Validation Gate

- the UI can be developed end-to-end without a live backend
- major browser flows can be demonstrated locally and deterministically

### Milestone 8: Frontend Test Strategy

#### Goal

Replace the old HTML-template/HTMX-oriented confidence model.

#### Deliverables

- unit tests for UI components and state logic
- generated-client contract tests
- mock-backed integration tests
- targeted browser end-to-end tests for critical flows
- replacement strategy for old UI tests that assumed server-rendered HTML

#### Validation Gate

- every critical UI flow has a planned automated test layer
- confidence no longer depends on the removed HTMX implementation

### Milestone 9: UI Packaging and Runtime Build

#### Goal

Package the SPA as a proper appliance artifact.

#### Deliverables

- Node-based frontend asset build
- compiled production SPA bundle
- production container image for the new UI runtime
- updated UI packaging flow in `appliance-code`
- updated release-input expectations in `appliance-release`
- updated install/import expectations in `appliance-ctl`

#### Validation Gate

- the new UI can be built reproducibly in the release flow
- the appliance bundle still treats the UI as a first-class signed artifact

### Milestone 10: Release and Install Contract Updates

#### Goal

Keep the release, preload, import, install, and upgrade paths valid.

#### Deliverables

- update release-input metadata assumptions as needed
- update bundle assembly tests
- update UI artifact handling tests
- update install and upgrade test expectations that depend on current UI build
  details

#### Validation Gate

- signed bundle assembly still succeeds
- `zonctl` import/install/upgrade assumptions remain correct

### Milestone 11: Shared Build Environment Updates

#### Goal

Make the shared build/dev image capable of building the frontend.

#### Deliverables

- update `../development-container` so the shared `dev-build` image includes
  Node and package-manager-capable support
- keep project-specific React/Vite dependencies inside the UI project itself
- document the intended use by the appliance repos

#### Validation Gate

- the shared Linux build container can build the frontend and final UI image
- the build environment remains reproducible and does not depend on ad hoc host
  setup

### Milestone 12: Documentation Closure

#### Goal

Finish the planning artifacts before implementation begins.

#### Deliverables

- architecture docs
- OpenAPI ownership guidance
- local frontend workflow docs
- mock mode usage docs
- packaging/build flow docs
- retirement of HTMX-era guidance

#### Validation Gate

- a contributor can understand the target architecture and workflow from docs
  before code starts

## Repo-By-Repo Deliverables

### `appliance-code`

- remove `services/ui`
- add `services/controlplane-ui`
- complete the OpenAPI spec
- generate and integrate a TypeScript API client
- implement the SPA auth/session model
- implement mock mode
- replace old UI tests with frontend-appropriate tests
- build and package the new UI runtime image

### `appliance-release`

- update UI packaging/build flow assumptions
- update release-input and bundle assembly scripts if source/build paths change
- update verification flow references to the new UI source/build path
- capture contributor workflow docs for the new UI build chain

### `appliance-ctl`

- update release-input tests
- update bundle assembly tests
- update install/import/upgrade tests that depend on current UI artifact
  production details

### `development-container`

- add Node/TypeScript build support to the shared `dev-build` image
- keep app-specific frontend libraries out of the base image
- document the new intended use for appliance repo frontend builds

## Implementation Readiness Gates

Before coding starts, the following must be true:

- the full UI feature surface is audited
- the control-plane OpenAPI surface is complete enough for SPA use
- the browser auth and refresh model is documented
- local dev modes are defined
- the mock backend strategy is defined
- the packaging and build-environment impact is understood

## UI Design and UX Constraints

The new UI should be designed as a sleek, simple, professional infrastructure
appliance console.

### High-Level Design Direction

- professional appliance-console tone, not consumer SaaS
- simple, sleek, low-noise visual language
- fast and light, not heavy
- desktop-first quality with clean responsive behavior down to mobile layouts
- few colors:
  - black
  - white
  - grays
  - one brand highlight color
- initial brand highlight color:
  - dark navy blue
- success and healthy-state indicators should use a clean green

### Layout Direction

#### Login page

- left side: branded product/appliance image or illustration
- right side: standard professional login panel
- should feel like a large-enterprise appliance login experience

#### Global shell

- top header bar
- left side of header:
  - logo
  - product name
- right side of header:
  - search
  - notifications with count
  - help / question-mark affordance
  - user icon and dropdown menu

#### User menu

The user-specific area should support a dropdown or user panel with options
such as:

- preferences
- change password
- manage API keys
- user login details
- logout

#### Header utilities

- Search:
  - not required to be functional in the first release
  - may be omitted initially instead of shipping an empty control
  - can be introduced later when there is meaningful searchable application
    content
- Notifications:
  - important long-term appliance-level capability
  - intended to represent alerts, alarms, and operator-relevant events across
    the appliance
  - likely future backend support: notifications or alerts API with counts and
    latest items
  - first UI release may ship a reserved shell location or placeholder UI, but
    full behavior depends on follow-up backend work
- Help / question-mark affordance:
  - should have a reserved place in the shell
  - intended future contents:
    - about page
    - appliance version/details
    - what's new
    - help center
    - ask for help / support-oriented entry points
  - UI structure should be ready even if some items begin as static or partial

#### Main navigation

Use a left-side navigation panel with clear appliance-console groupings:

- Home
- Manage
- Analyze
- Admin

`Home` is the default landing page and should render the main dashboard view for
the signed-in user. There is no separate primary left-nav `Dashboard` item.

These sections are higher-level navigation groupings and should be mapped onto
current product functionality without inventing new backend capability.

#### Navigation behavior

- The left rail should behave like a compact appliance-console launcher.
- The top-level entries should feel closer to an icon-first tool rail, similar
  in spirit to compact IDE-style navigation.
- When a top-level area such as `Manage`, `Analyze`, or `Admin` is selected, a
  subpanel should open to let the user choose a concrete area within that mode.
- After the user chooses an area from that subpanel, the main content page for
  that area should open in the primary panel.

#### Navigation rule

Use this interaction model consistently across the application:

1. The user selects a top-level left-rail mode such as `Home`, `Manage`,
   `Analyze`, or `Admin`.
2. The selected mode resolves its available feature options.
3. If the mode has multiple feature options, a subpanel opens and lets the user
   choose one.
4. If the mode has exactly one default feature option, or effectively no
   separate feature list, the app navigates directly to that page layout
   without showing an intermediate feature picker.
5. The main content area navigates to the resolved feature page layout.
6. Inside that page, clean page-level tabs expose the major sub-sections of
   the selected feature or mode.

This pattern should be treated as a global UI rule so the product stays
consistent as more features are added.

Initial examples for the first release:

- `Home`
  - default dashboard
  - behaves like a mode with a single default destination and no meaningful
    intermediate feature list
  - page-level tabs such as `Overview` first, with room for future home tabs
- `Manage`
  - DNS management entry point
- `Analyze`
  - workflow analysis entry point
- `Admin`
  - appliance-wide admin-oriented areas as current product functionality allows
  - initial candidates:
    - system status
    - profiles
    - licensing

`Manage` may initially contain limited or placeholder sections where current
product functionality is still sparse, but the layout should be ready for more
configuration-oriented features over time.

`Analyze` should be structured for feature-specific drill-downs. For the
current scope, it should anticipate workflow-centric analysis such as counts of
successful and failed workflows-engine-driven workflows and related summary views as that
data surface becomes available.

`Admin` should be structured as the appliance-wide operations and platform
area. Even where backend depth is still limited, the UI should reserve a clean
place for operational capabilities that will expand over time, such as:

- system status
- system software details
- profiles
- licensing
- metrics and service health
- support data collection and log bundle flows

#### Page tabs

- use clean, light page tabs within the selected area page
- tabs should feel seamless and simple, similar in spirit to GitHub's
  page-level tab navigation
- tabs are not just cosmetic view toggles; they should represent major
  sub-sections within the current mode/page
- example pattern:
  - a selected `Manage` area opens a page
  - tabs inside that page switch among the major sub-sections of that area

### Interaction and Responsive Constraints

- must work cleanly on desktop browsers
- must also work cleanly on mobile browsers
- responsive behavior should be intentional, not accidental
- cards, workflows, and data panels should collapse gracefully on smaller
  screens
- workflow UX should remain clean if current or future flows include
  provisioning/build state progression

### Functional UX Scope

- `Home` is the main dashboard and default landing page
- `Home` should be modeled generically as a mode with a single default
  destination rather than as a hardcoded one-off navigation exception
- `Manage` is the configuration-oriented mode
- `Analyze` is the data/insight-oriented mode
- `Admin` is the appliance-wide administrative mode
- the UI should add workflows and cards only for the functionality that is
  already implemented in the current UI surface, plus sensible placeholders
  where a mode exists but current feature depth is still small
- no additional product functionality is required at this stage

## External Design References

The design direction may draw inspiration from Cisco Nexus Dashboard's
navigation and appliance-console structure, especially its use of:

- a common navigation bar
- search and notification affordances
- a user menu with account actions
- permission-aware admin console structure

Relevant Cisco references reviewed during planning:

- Cisco Nexus Dashboard GUI Overview:
  `https://www.cisco.com/c/en/us/td/docs/dcn/nd/2x/user-guide-23/cisco-nexus-dashboard-user-guide-231/gui_overview.html`
- Cisco Nexus Dashboard Exploring Your Dashboard:
  `https://www.cisco.com/c/en/us/td/docs/dcn/nd/4x/articles-421/exploring-your-nd.html`
- Cisco Nexus Dashboard product overview:
  `https://www.cisco.com/site/us/en/products/networking/cloud-networking/nexus-platform/index.html`

These references are design inspiration only. The Zon UI should remain its own
product and should not copy vendor-specific branding or information
architecture mechanically.

## Remaining Discussion Topics

The following areas may still need product discussion before implementation:

- final brand treatment for the login image/illustration
- exact notification model in the first SPA release
- precise mobile navigation behavior:
  - collapsible sidebar
  - bottom-nav alternative
  - drawer behavior
- exact subpanel structure and tab layout inside each major mode as the
  detailed feature pages are designed

These are design and UX shaping topics, not blockers for the technical
migration plan itself.

## Execution Defaults

Unless explicitly changed during implementation review, use these defaults so
execution can begin without reopening core planning decisions:

- Source path:
  - new UI source lives in `appliance-code/services/controlplane-ui`
  - legacy `appliance-code/services/ui` is removed
- Frontend stack:
  - React
  - TypeScript
  - Vite
- API contract:
  - browser uses only the control-plane OpenAPI surface
  - generated TypeScript client is the default API access layer
- Navigation model:
  - left rail selects a top-level mode
  - modes with multiple features open a subpanel
  - modes with a single default destination navigate directly
  - each destination page owns its own page-level tabs
- Home mode:
  - default landing page after sign-in
  - main dashboard view
  - first tab is `Overview`
- Initial mode mapping:
  - `Home` -> dashboard
  - `Manage` -> DNS first, with room for future configuration pages
  - `Analyze` -> workflow analysis first, with room for future analysis pages
  - `Admin` -> appliance-wide admin areas supported by existing product
    capability, starting with system status, profiles, and licensing-oriented
    pages or placeholders
- Local development:
  - support mock backend mode
  - support local real-control-plane mode
  - support remote appliance mode
  - use a frontend dev proxy rather than widening product CORS by default
- Visual baseline:
  - neutral palette with dark navy highlight
  - professional appliance-console style
  - responsive desktop/mobile layout
- First-release shell behavior:
  - search may be omitted initially if there is no meaningful first-release
    behavior behind it
  - notifications may ship as shell structure or placeholder UI pending
    backend API support
  - help/about affordances should have a reserved shell location even if some
    destinations begin as static or partial pages
