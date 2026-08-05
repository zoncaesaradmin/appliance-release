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

Day-to-day e2e:

```bash
bash .agents/skills/release/scripts/run-release-from-devhost.sh \
  --config ~/lab-devhost.yaml \
  --build-publish-config ~/lab-build-publish.yaml \
  --install-config ~/lab-install.yaml
```

CLI path presence selects stages (no `build_flow.skip` / `install.skip`):

- `--build-publish-config` → build/publish on the build host
- `--install-config` → public helper install → optional bootstrap → target/client verify → report

Secrets stay in the Mac shell as env vars **named** by config `*_env` keys
(`DEV_*`, `APPLIANCE_BUILD_SUDO_PASSWORD`, `APPLIANCE_TARGET_SUDO_PASSWORD`,
`APPLIANCE_FIRST_ADMIN_PASSWORD` when `install.bootstrap_admin` is true).

Important rules:

- use SSH aliases, not raw IPs when practical
- use absolute remote paths, not `~/...`
- do not store passwords in the config
- appliance state dir is product-fixed `/var/lib/zon/state` (not YAML)
- packaging always builds the **complete product super-set**;
  `install.appliance_profile` only selects modules at install

`bundle_store.mode`:

- `static_http` — open base URL
- `appliance_files` — `https://$DEV_REGISTRY/api/v1/files` (+ token/TLS env)

## Scripts (e2e call graph)

**Entry**

- `scripts/run-release-from-devhost.sh` — only day-to-day e2e entry

**Build path**

- `scripts/run-build-and-publish-on-build-host.sh` — Mac: scp config, inject env, SSH
- `scripts/build-and-publish-on-host.sh` — build-host wrapper
- `scripts/build-and-publish.sh` — bootstrap / build / publish / artifact metadata
- `scripts/validate-release-artifacts.py` — post-publish validation

**Install path**

- `scripts/run-install-via-public-helper-on-target.sh` — Mac: curl published
  `install-http-release.sh` on target (sudo from Mac)
- Product script lives under repo `scripts/publish/install-http-release.sh` (published with the release)

**Post-install (from install YAML flags)**

- `scripts/bootstrap-admin-on-target.sh` — when `install.bootstrap_admin`
- `scripts/bootstrap-default-license-on-target.sh` — when `install.enable_default_license`
- `scripts/verify-target.sh` — after install
- `scripts/verify-client-access.sh` — when bootstrap_admin (Mac client/API)
- `scripts/verify-artifact-access.py` — OCI registry checks from client verify

**Shared + report**

- `scripts/common.sh` / `scripts/config_query.py`
- `scripts/validate-build-catalog.py` — builder catalog validation
- `scripts/summarize-release-run.py` — `metadata/release-report.json` + markdown

Every stage takes only the role configs it needs (`--config` = devhost,
`--build-publish-config`, `--install-config`). There is no merge step.

## Workflow

1. Assume the user already made local changes and pushed them unless they ask for local code work.
2. Read the active repositories' `AGENTS.md` files.
3. Prefer `run-release-from-devhost.sh` with the three configs.
4. Summarize run-dir metadata, checksums, install, and verify results after the run.

## Command Selection Guidance

- Prefer existing repo scripts and Make targets over ad hoc commands.
- Do not auto-retry failed build/publish with modified commands unless the user asks.
- If a step needs `sudo`, supply it at runtime without writing it to disk.
