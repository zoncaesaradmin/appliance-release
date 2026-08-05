---
name: appliance-release
description: Orchestrate the Zon appliance developer-to-target workflow across local repos, a remote build server, an artifact HTTP server, and one target host. Use when the user wants Codex to take code changes through local validation, workspace sync, remote build/publish, target install, post-install verification, and a final release report without hardcoding machine-specific details.
---

# Appliance Release

Use this skill when we need to drive the repeatable Zon appliance release path from a macOS development machine through a build server, a release distribution backend (preferably an external HTTP static server, or the appliance-managed authenticated file API), and onto a target host.

## What This Skill Owns

- repeatable remote execution, install, and verify mechanics
- run-directory layout, log capture, and metadata capture
- final report inputs: commits, artifacts, digests, install result, verification result

## Source Of Truth

This skill is intended to live in the `appliance-release` repository and be
tracked in git at one path:

- `.agents/skills/release`

All skill docs, examples, and helper scripts live inside that directory.

## What This Skill Does Not Own

- repository-specific architecture or coding rules
- exact build, test, or publish commands when those belong to a repo's `AGENTS.md`
- secrets, SSH keys, or stored passwords

Read each participating repository's `AGENTS.md` before making code or command decisions. For the current Zon layout, that usually includes:

- `appliance-release`
- `appliance-ctl`
- `appliance-code`

## Configuration

Configs are **three YAML/JSON files** (one role each). Start from:

- [config.devhost.example.yaml](references/config.devhost.example.yaml) — Devhost: `build_host`, `target_host`, `report`
- [config.build-publish.example.yaml](references/config.build-publish.example.yaml) — build/publish
- [config.install.example.yaml](references/config.install.example.yaml) — install + verify

Index: [config.example.yaml](references/config.example.yaml).

The orchestrator merges the three (disjoint keys) into one temporary document for
stage workers. Secrets stay in the Mac shell as env vars **named** by config
`*_env` keys.

Important rules:

- use SSH aliases, not raw IPs
- use absolute remote paths, not `~/...`
- do not store passwords in the config
- keep machine-specific values in the config, not in the skill
- put every required operational value in the config (scripts fail closed when a
  key is missing; fixed lab defaults belong in YAML, not hardcoded in scripts)
- packaging always builds the **complete product super-set** (Argo, Zot, DNS,
  host-packages for mdns+wifi-ap, workspace-provisioner, `registry.local/dev-build`).
  `install.appliance_profile` only selects modules at install; host mDNS / Wi-Fi AP
  enablement is day-2 Admin UI/API only (packages always staged, services off)

Runtime secrets such as remote `sudo` passwords and first-admin credentials must be supplied at runtime, not written into the skill. Prefer environment variables or an interactive prompt.

For day-to-day use, pass all three config paths and set secret-bearing shell env only:

- `DEV_REGISTRY=...` (named by `build_flow.dev_image_pull.registry_env`; also used by appliance-code `SERVICE_IMAGE_REGISTRY`)
- `DEV_IMAGE_REPO=...` / `DEV_IMAGE_NAME=...` (named by pull `image_repo_env` / `image_name_env` — development-container only)
- `DEV_REGISTRY_USER=...` / `DEV_REGISTRY_TOKEN=...` (named by `dev_image_pull` username/token env keys; also optional LAN pull on install)
- `DEV_REGISTRY_TLS_VERIFY=true|false` (named by `dev_image_pull.tls_verify_env`)
- Optional `build_flow.build_image_mirror` — separate from `dev_image_pull` so the
  DevContainer Artifact Server and a build-time OCI pull-through mirror can
  differ later. For now use the same env names (`DEV_REGISTRY*`). When `enabled:
  true`, builds try `<registry>/<repository_prefix>/<image>:<tag>` first with
  `timeout_seconds`, then fall back to the public upstream, then best-effort
  push to seed the mirror. Omit or `enabled: false` leaves internet-first pulls.
- Optional `install.image_pull_registry` in config (`registry_env` + credential env names; no literal `registry`) so target K3s can pull from the LAN registry
- Do not set `build_flow.product_publish` — that block is rejected; use `bundle_store` for signed-bundle publish
- `APPLIANCE_BUILD_SUDO_PASSWORD=...`
- `APPLIANCE_TARGET_SUDO_PASSWORD=...`
- `APPLIANCE_FIRST_ADMIN_PASSWORD=...`

Distribution modes (`bundle_store.mode`): `static_http` or `appliance_files`
(appliance-managed authenticated file API). Mode and `release_path_prefix` are
required. `static_http` also needs `base_url` / publish server fields.
For `appliance_files`, connection derives from env (same as image pull):
`https://$DEV_REGISTRY$files_path` (default `files_path: /api/v1/files`),
bearer `$DEV_REGISTRY_TOKEN`, TLS from `$DEV_REGISTRY_TLS_VERIFY` (`false` →
curl `-k`). Optional config: `registry_env` / `token_env` / `tls_verify_env` /
`files_path`, plus overrides `base_url` / `access_token` / `tls_insecure` /
`cacert_path`. Traefik `/files` was removed. Historical aliases: `http`/
`http-static` → `static_http`, `fileserver` → `appliance_files`.

## Scripts

- `scripts/run-release-flow.sh`
  One-shot end-to-end wrapper. **CLI options only:**
  `--config` (Mac), `--build-publish-config`, `--install-config`.
  Stage switches sit on `build_flow.skip`, `install.*`, and `report.*` in those files.
- `scripts/build-and-publish.sh`
  Run the deterministic build-host flow: sync the skill-managed release checkout, optional bootstrap, bundle build, publish, and artifact metadata capture. Publish uses `bundle_store.mode` (`static_http` or `appliance_files`).
- `scripts/install-on-target.sh`
  Optionally uninstall the previous appliance, then install the published release on the target host via HTTP `curl` against `base_url` (Mac only SSHs).
- `scripts/bootstrap-admin-on-target.sh`
  Create the first administrator on the target. Invoked by `run-release-flow.sh`
  when `install.bootstrap_admin` is true.
- `scripts/bootstrap-default-license-on-target.sh`
  Accept the base/free entitlement. Invoked by `run-release-flow.sh` when
  `install.enable_default_license` is true.
- `scripts/verify-target.sh`
  Run post-install verification, service-health checks, smoke checks, and failure-log capture.
- `scripts/verify-client-access.sh`
  Run macOS-side client/API checks against the appliance after first-admin setup.
- `scripts/plan-profile-matrix.py`
  Generate, but do not execute, the final core/storage/builder profile-matrix
  command plan and validate required builder workflow config inputs.
- `scripts/audit-profile-matrix-reports.py`
  Audit the generated `release-report.json` files after the real
  core/storage/builder profile-matrix runs and fail closed on missing profile,
  disabled-route, builder-tool, or builder workflow evidence.
- `scripts/common.sh`
  Shared helpers for config resolution, logging, SSH execution, and secret loading.
- `scripts/config_query.py`
  Shared YAML/JSON query helper used by the shell scripts.

## Workflow

1. Assume the user already made local changes and pushed them to the relevant repos unless they explicitly ask for local code work in the same task.
2. Read the active repositories' `AGENTS.md` files before deciding which remote commands are safe.
3. Create a run directory, usually under the release repo at `.run/appliance-release/<timestamp>`.
4. Prefer `scripts/run-release-flow.sh` for the common end-to-end path.
5. If you need more control, run `build-and-publish.sh`, `install-on-target.sh`, `verify-target.sh`, and `verify-client-access.sh` individually.
6. Summarize the captured metadata and logs after the wrapper or individual steps finish.
7. Summarize:
   - release version
   - source commits that were built
   - build/publish results
   - artifact checksums and image digests that were captured
   - installation result
   - target-host verification result
   - client/API verification result
   - warnings, failures, and log locations

## Command Selection Guidance

This skill should orchestrate, not invent infrastructure behavior.

- Prefer existing repo scripts and Make targets over ad hoc command construction.
- If a repo already has a build or publish entrypoint, configure that exact command for `build-and-publish.sh`.
- If a repo already has a smoke or verification command, prefer that over writing a new one.
- Do not auto-retry failed build or publish steps with modified commands unless the user asks for that.
- If a step needs `sudo`, supply it at runtime without writing it to disk.

## Typical Use In This Repository Family

For the current three-repo flow:

- the user usually pushes repo changes first
- the build host ensures `appliance-release` exists at `release_workspace.remote_repo_path` (cloning on first use, then fetch + hard-reset to `remote_repo_ref` on later runs, discarding any dirty local files)
- the build host bootstrap may require `sudo`
- remote build runs the release repo's CI-style bundle build
- remote publish runs the release repo's publish flow against the HTTP server
- target install uses the published HTTP installer helper
- macOS-side verification logs into the appliance API and checks session/users endpoints

See [references/script-usage.md](references/script-usage.md) for concrete example commands.
