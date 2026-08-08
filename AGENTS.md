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

## Workload Identity And Storage Security

- Run K3s rootful for the initial appliance baseline, but require appliance application containers to run as non-root.
- Assign fixed numeric UID/GID values for every component and keep them stable across releases; never rely only on Linux usernames in charts, manifests, diagnostics, or docs.
- Use pod-level `runAsUser`, `runAsGroup`, `runAsNonRoot`, `fsGroup`, and `fsGroupChangePolicy: OnRootMismatch` for application and workflow pods.
- Use distinct per-component UIDs/GIDs and a separate shared filesystem GID for writable storage shared across components or workflow pods. The shared GID must not be the same number as a service UID.
- Use setgid directories and group-writable modes such as `2770` for shared writable storage; never use `chmod 777` as the normal solution.
- Give each service its own PVC unless the storage is genuinely shared. Treat every writable host mount or `hostPath` as a security-sensitive product interface that must be documented, ownership-checked, and preserved or wiped only by explicit lifecycle policy.
- Builder workspace source trees live under `/data/zon/workspaces` and must survive factory reset by default; wipe them only when an explicit workspace-wipe lifecycle option such as `zonctl factory-reset --wipe-workspaces` is implemented, documented, and invoked.
- Runtime service logs live under the appliance data path `/data/zon/logs/<service>/`, not under the system log tree.
- Runtime service log directories are an operator-facing inspection interface: keep them service-owner writable, but host-user readable/traversable, normally mode `2755`. Do not treat them like private shared writable workspace storage.
- Keep application container root filesystems read-only and mount only explicit writable paths.
- Use root init containers only as documented, narrow ownership-preparation or migration mechanisms.
- Validate normal workloads against Pod Security Admission, preferably the Restricted profile. Any required exception, such as a documented host-visible workspace or host log path, must be explicit.
- Installer, verification, reports, and diagnostics must include storage ownership and writeability checks for appliance-owned writable paths, including service log directories and builder workspace storage.
- Test fresh install, upgrade, rollback, backup restore, and machine migration paths when changing UID/GID, storage, PVC, hostPath, or ownership behavior.

## Packaging Code Reuse (Online And Offline)

- Core packaging must stay **minimal and shared**. Online and offline build-host flows must not grow parallel copies of the same logic.
- There are exactly **two** build-host modes — not a mix per dependency:
  - **Online:** every third-party / tooling input is fetched from the public internet (or the configured public registry path such as GHCR). No LAN Artifact Server seed is required; do not probe LAN build-cache and fall back upstream per image.
  - **Offline:** every such input is fetched only from the LAN Artifact Server (`DEV_REGISTRY` OCI + files API) after `make seed-build-deps` (or equivalent). Misses fail closed; no public upstream fallback.
- One flag / mode selects the policy for **all** dependencies together (dev-build, git-runtime, Argo, zot, CoreDNS, Ollama/inference-runtime, build bases, Helm, K3s, CRDs, host-packages, …). Do not keep separate “this one from GHCR, that one from LAN, that one from Docker Hub with cache” paths.
- Unify early: config may expose `ONLINE_*` (online tooling) and `DEV_*` (LAN).
  After mode selection, map the active pull into one fixed `DEV_*` identity for
  bootstrap/build. Offline pull already *is* `DEV_*` — do not invent a parallel
  `OFFLINE_*` family. Publish uses `bundle_store` (also `DEV_*`). Packaging
  scripts must not branch on `ONLINE_*`.
- Prefer one implementation path for resolving and packaging a dependency. Online vs offline differs only in **source policy** (upstream vs LAN via `OFFLINE_BUILD`), not in duplicated packaging steps or per-case special cases.
- Do not add “offline-only” and “online-only” forks of the same script when a common function with a single source policy switch can serve both.
- New dependency seeding under `deps/` must feed the offline mode of that shared path. Seed helpers and packaging consumers share code (for example `scripts/deps-common.sh`) rather than re-implementing pull/push/upload separately.
- **Whenever you add a new third-party / upstream image or file input to packaging** (export script, `build-full-bundle`, release-input, chart wrap, etc.), you **must** also:
  1. Add or extend a `deps/<name>/` seed package (`pins.env`, `scripts/build.sh`, `scripts/push.sh`, Makefile, README) so `make seed-build-deps` publishes it to LAN `build-cache` / files API.
  2. Remap that input in the offline branch of the shared packaging path (`lan_cache_ref` / files API) so `OFFLINE_BUILD=1` never pulls public upstream.
  3. Keep the online path pulling the same pinned upstream directly.
  4. Update `docs/offline-build-deps.md`, example configs / comments that list seeded packages, and any validator that asserts pairing.
  A change that only wires the online export without the `deps/` seed + offline remap is incomplete.
- When changing packaging, converge on the shared path and remove hybrid LAN-then-internet leftovers from older flows.

## Shared `dev-build` tooling image (LAN + GHCR)

- Canonical sources live in `deps/development-container/` (not a separate git repo).
- The published image name is `dev-build`. It is used for:
  - **build-host packaging only** (online pull from GHCR; offline pull from LAN after seed)
  - **local / day-2 service builds** outside packaging — `appliance-code`
    `make dev-shell`, control-plane image, control-plane UI image, host-agent
    image, and similar tooling-container builds
- **`dev-build` is not a product runtime image.** It is not packaged into the
  base, developer, or inference packs. Operator build catalogs must use
  explicit digest-pinned builder images they supply on the appliance.
- Each platform release publishes three signed deliverables: base bundle,
  `developer` pack (Argo + workspace-provisioner), and `inference` pack.
  Install selects packs from the profile (`core` does not include workflows).
- `make seed-build-deps` publishes `dev-build` to the **LAN Artifact Server only**.
  That does **not** update GHCR.
- Whenever `deps/development-container` content changes (Containerfiles, pins,
  toolchain versions), operators must publish the **same** image to **both**:
  1. LAN — `make seed-build-deps` or `make -C deps/development-container release` with LAN `DEV_*`
  2. GHCR — **manual** second publish with `DEV_REGISTRY=ghcr.io` and
     `DEV_IMAGE_REPO=<owner>/development-container` (see
     `deps/development-container/PACKAGE.md`)
- Leaving only the LAN copy updated breaks online packaging and local
  `appliance-code` image builds that still pull from GHCR. Do not skip the GHCR
  push after a tooling-image change.

## Local Verification Discipline

- Any time you edit this repository, run `make verify` in this repository before considering the work complete.
- Apply this even for small code, script, workflow, test, Makefile, or documentation changes unless the user explicitly tells you not to run verification.
- If `make verify` fails, fixing that failure becomes the first follow-up task before any further feature work or close-out.
- Do not treat the task as done while `make verify` is failing. Either fix the failure or report the exact blocker and the failing log/location.

## End-To-End Fix Discipline

- Full dependency map, OCI contract, change→check matrix, and done-gate: `.cursor/rules/appliance-cross-repo-e2e.mdc` (always applied).
- Before closing any bug fix that touches packaging, install, image preload, charts, workflows, or cross-repo contracts, walk the full operator path: export → release-input → signed bundle → zonctl preload/import/tag → Helm values/config → control-plane → workflow/workload image resolve → observable success.
- A change is incomplete if it only updates one side of a producer/consumer pair (for example packaging writes `registry.local/<name>:bundled` while zonctl still requires annotation == digest pin). Update every dependent check, test, docs/example, and sibling repo in the same fix set.
- Do not treat “make verify passed in one repo” as sufficient when the release flow spans `appliance-release`, `appliance-ctl`, and `appliance-code`; verify each edited repo and explicitly re-check the shared contract.
- Do not hand off another long release-flow run while a known cross-repo contract mismatch remains.

## Real Setup Guardrail

- Do not run real-environment verification flows unless the user explicitly asks for that exact run in the current turn.
- Specifically, do not run a config with `build_flow.skip` / `install.skip`
  set for "verify against the real setup only" on behalf of the user (and do not
  invent extra CLI flags on `run-release-from-devhost.sh` — only the three config paths
  are allowed).
- Do not use the user's real build server, publish server, or target device for validation after code changes unless the user explicitly asks for that execution in the current turn.
- Hand off the exact command(s) for the user to run instead of consuming the real setup automatically.
- Real build/publish/target hosts are **read-only by default** for the agent. SSH may be used to inspect logs and state, but the agent must not modify files or content on those hosts (`scp` uploads, remote edits, `git reset`/`checkout`/`clean`, package installs, image imports, cluster changes) unless the user explicitly authorizes that write in the current turn. Change code locally and sync through git / the release skill instead of hot-fixing the build server.
- Do not edit user runtime files outside the repo (for example `~/appliance-release.config.yaml` or `~/build-catalog.yaml`). Change only in-repo examples/references and tell the user what to copy into their personal config.

## Repository Boundary

- Consume only signed/pinned release inputs from private `appliance-code` outputs.
- Never clone private product source, rebuild or patch the control-plane image, fork the canonical chart, or redefine product security behavior.
- Reject invalid product inputs and require a new candidate from `appliance-code`.
