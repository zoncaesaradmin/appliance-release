---
name: appliance-release
description: Orchestrate the Zon appliance developer-to-target workflow across local repos, a remote build server, an artifact HTTP server, and one target host. Use when the user wants Codex to take code changes through local validation, workspace sync, remote build/publish, target install, post-install verification, and a final release report without hardcoding machine-specific details.
---

# Appliance Release

Use this skill when we need to drive the repeatable Zon appliance release path from a macOS development machine through a build server, an HTTP publish server, and onto a target host.

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

The scripts read a local YAML or JSON config file. Start from [references/config.example.yaml](references/config.example.yaml).

Important rules:

- use SSH aliases, not raw IPs
- use absolute remote paths, not `~/...`
- do not store passwords in the config
- keep machine-specific values in the config, not in the skill

Runtime secrets such as remote `sudo` passwords and first-admin credentials must be supplied at runtime, not written into the skill. Prefer environment variables or an interactive prompt.

For day-to-day use, set:

- `APPLIANCE_RELEASE_CONFIG=/abs/path/to/appliance-release.config.yaml`
- `REGISTRY_USER=...`
- `REGISTRY_TOKEN=...`
- `APPLIANCE_BUILD_SUDO_PASSWORD=...`
- `APPLIANCE_TARGET_SUDO_PASSWORD=...`
- `APPLIANCE_FIRST_ADMIN_PASSWORD=...`

Once `APPLIANCE_RELEASE_CONFIG` is set, the scripts can usually be run without `--config`.

## Scripts

- `scripts/run-release-flow.sh`
  One-shot wrapper for the common flow from the `appliance-release` repo: build/publish, install, target verify, then macOS-side API verify.
- `scripts/build-and-publish.sh`
  Run the deterministic build-host flow: optional `git pull`, build-host bootstrap, bundle build, publish, and artifact metadata capture.
- `scripts/install-on-target.sh`
  Optionally uninstall the previous appliance, then install the published release on the target host via the HTTP installer helper.
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
