# Zon Platform Installer Invariants

These rules apply to all code, scripts, tests, workflows, and documentation in this repository. The CLI is `zonctl`.

## Installation Model

- V1 has one production package: the complete signed air-gapped appliance bundle produced from pinned `appliance-code` inputs.
- Installation, startup, normal operation, authentication, builds, registry use, backup, restore, diagnostics, and upgrade must not require public internet access.
- Do not add a connected installer, install-time downloader, remote package repository requirement, phone-home behavior, external license check, dynamic plugin fetch, or background internet updater.

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
- Treat partial prior attempts as a first-class state. Install and upgrade must converge cleanly when rerun after an interrupted or failed attempt: every installer-owned mutation must either be overwritten safely in place or explicitly cleaned up/rolled back so the next run can continue without manual cluster surgery.

## Packaging and Versioning

- Helm is the standard deployment mechanism. Each major platform component (`zon-core`, `zon-api`, `zon-ui`, `zon-registry`, `zon-observability`, ...) ships as its own Helm chart.
- Maintain two independent version levels: a **platform version** (the complete tested release, pinning the supported K3s version and every chart/image version) and independent **per-service versions** that may evolve while remaining compatible with a given platform release.
- The installer is **manifest-driven**, not hardcoded: the signed release manifest and bundle entries define the platform version, supported K3s version, chart/image versions, enabled components, default configuration, and migration information. `zonctl` reads these verified inputs rather than embedding release values in code.
- Do not introduce build-time target-specific hostnames, IP addresses, URLs, TLS names, or origins into the release bundle workflow. A bundle must remain portable across target hosts; target identity belongs to install-time or post-install configuration, not product-bundle assembly inputs.

## Verification

- Every artifact the installer selects must be present in the signed bundle and is checked against the release manifest's pinned digest/version before use.
- The installer fails closed: it never silently proceeds when a required artifact is missing, invalid, or fails verification, and it never falls back to an unpinned or unverified source.
- Secrets are generated on the target or supplied through protected files/descriptors. They never appear in Git, release artifacts, command arguments, logs, or support bundles.

## Local Verification Discipline

- Any time you edit this repository, run `make verify` in this repository before considering the work complete.
- Apply this even for small code, script, workflow, test, Makefile, or documentation changes unless the user explicitly tells you not to run verification.
- If `make verify` fails, fixing that failure becomes the first follow-up task before any further feature work or close-out.
- Do not treat the task as done while `make verify` is failing. Either fix the failure or report the exact blocker and the failing log/location.

## Real Setup Guardrail

- Do not run real-environment verification flows unless the user explicitly asks for that exact run in the current turn.
- Specifically, do not run `run-release-flow.sh --skip-build --skip-install` or similar "verify against the real setup only" commands on behalf of the user.
- Do not use the user's real build server, publish server, or target device for validation after code changes unless the user explicitly asks for that execution in the current turn.
- Hand off the exact command(s) for the user to run instead of consuming the real setup automatically.

## Repository Boundary

- Consume only signed/pinned release inputs from private `appliance-code` outputs.
- Never clone private product source, rebuild or patch the control-plane image, fork the canonical chart, or redefine product security behavior.
- Reject invalid product inputs and require a new candidate from `appliance-code`.
