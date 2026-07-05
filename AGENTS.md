# Zon Platform Installer Invariants

These rules apply to all code, scripts, tests, workflows, and documentation in this repository. The CLI is `zonctl`.

## Installation Model

- V1 supports **online installation**: `zonctl install` fetches K3s, Helm, the platform chart, and images over the network as needed on a supported host.
- **Offline (air-gapped) installation is a planned future phase** that must reuse the identical installation workflow — the only difference between online and offline modes is where resources are obtained (network fetch vs. a local signed bundle), never the installation logic itself.
- Do not hardcode online-only or offline-only assumptions into the install sequence. Resource acquisition (K3s binary, Helm, chart, images) must sit behind a single pluggable source abstraction so both modes share one code path.

## Supported Operating System

- Officially supported: Ubuntu Server 22.04 LTS and Ubuntu Server 24.04 LTS, `amd64`.
- Block installation outright on non-Ubuntu operating systems and on unsupported Ubuntu versions.
- Ubuntu Desktop may be allowed later as an explicit advanced/unsupported mode; it is not part of the supported matrix today.

## Platform Ownership

- Zon owns K3s installation, Traefik configuration, Helm deployments, platform configuration, and service lifecycle. Operators must never be required to install or manage K3s manually.
- **Fresh install** (no K3s present): install the pinned K3s version, enable Traefik, ensure Helm is available, deploy every Zon platform Helm chart, run health checks, and print the platform URL and bootstrap information.
- **Existing K3s**: detect its version, cluster health, whether it is already Zon-managed, and whether it carries non-Zon workloads.
  - If safe to adopt (compatible or upgradeable version, no unrelated workloads), automatically upgrade K3s to the supported version if required and proceed.
  - If unrelated workloads are present, never silently modify the cluster — require an explicit adoption/force option before taking ownership.
- The installer is idempotent and safe to rerun in every mode above.

## Packaging and Versioning

- Helm is the standard deployment mechanism. Each major platform component (`zon-core`, `zon-api`, `zon-ui`, `zon-registry`, `zon-observability`, ...) ships as its own Helm chart.
- Maintain two independent version levels: a **platform version** (the complete tested release, pinning the supported K3s version and every chart/image version) and independent **per-service versions** that may evolve while remaining compatible with a given platform release.
- The installer is **manifest-driven**, not hardcoded: a platform manifest defines the platform version, supported K3s version, chart versions, image versions, enabled components, default configuration, and migration information. `zonctl` reads this manifest rather than embedding these values in code.

## Verification

- Every artifact the installer selects — fetched online or read from a future offline bundle — is checked against the platform manifest's pinned digest/version before use.
- The installer fails closed: it never silently proceeds when a required artifact is missing, invalid, or fails verification, and it never falls back to an unpinned or unverified source.
- Secrets are generated on the target or supplied through protected files/descriptors. They never appear in Git, release artifacts, command arguments, logs, or support bundles.

## Repository Boundary

- Consume only signed/pinned release inputs from private `appliance-code` outputs.
- Never clone private product source, rebuild or patch the control-plane image, fork the canonical chart, or redefine product security behavior.
- Reject invalid product inputs and require a new candidate from `appliance-code`.
