---
name: appliance-release
description: Orchestrate the Zon appliance developer-to-target workflow across local repos, a remote build server, the appliance file API on DEV_REGISTRY, and one target host. Use when the user wants Codex to take code changes through local validation, workspace sync, remote build/publish, target install, post-install verification, and a final release report without hardcoding machine-specific details.
---

# Appliance Release

Use this skill when we need to drive the repeatable Zon appliance release path from a macOS development machine through a build server, the appliance-managed authenticated file API on `DEV_REGISTRY`, and onto a target host.

## What This Skill Owns

- remote SSH/orchestration and run-directory / log / metadata capture
- install + verify mechanics on the target
- final report inputs: commits, artifacts, digests, install result, verification result

Product packaging and publish **implementation** is only this fixed sequence under repo `scripts/`:

1. `scripts/bootstrap-build-host.sh`
2. `scripts/build-full-bundle.sh`
3. `scripts/publish-release.sh`

This skill remotes that same sequence. It does not add a second product entrypoint.

## Source Of Truth

This skill is intended to live in the `appliance-release` repository and be
tracked in git at one path:

- `.agents/skills/release`

## What This Skill Does Not Own

- repository-specific architecture or coding rules
- the product build/publish implementation (see `scripts/` and `scripts/`)
- secrets, SSH keys, or stored passwords

Read each participating repository's `AGENTS.md` before making code or command decisions. For the current Zon layout, that usually includes:

- `appliance-release`
- `appliance-ctl`
- `appliance-code`

## Offline build-host dependencies

Third-party inputs for packaging live under **`appliance-release/deps/`**.

Exactly two bundle modes (config `build_flow.mode` / env `OFFLINE_BUILD`):

- **Online:** all third-party pulls from the public internet. Skill maps
  `online_image_pull` (`ONLINE_*`) → unified `DEV_*` for packaging.
- **Offline:** all third-party pulls only from the LAN Artifact Server after
  `make seed-build-deps`. `offline_image_pull` already names `DEV_*` (same
  LAN identity as publish/seed — no separate `OFFLINE_*` family).

After that mapping, bootstrap/build use only `DEV_*` + `OFFLINE_BUILD`.
Publish uses `bundle_store` (also `DEV_*`) for `publish-release.sh`.

Both modes must work for every packaging dependency (including `deps/inference`
/ Ollama). Adding a new third-party input requires a matching `deps/<name>`
seed package and an offline `lan_cache_ref` / files remap — see AGENTS.md and
`docs/offline-build-deps.md`.

`deps/development-container` (`dev-build`) is **build-host tooling only** (not a
product pack image). It is also the tooling
image for local `appliance-code` service builds. `make seed-build-deps` updates
LAN only; after changing that package, also publish manually to GHCR — see
`deps/development-container/PACKAGE.md` and AGENTS.md “Shared `dev-build`”.

Seed (offline prerequisite):

```bash
cd /path/to/appliance-release
export DEV_REGISTRY=... DEV_REGISTRY_USER=... DEV_REGISTRY_TOKEN=...
export DEV_REGISTRY_TLS_VERIFY=false
export DEV_IMAGE_REPO=development-container
make seed-build-deps
```

Skill config: see `references/config.build-publish.example.yaml`
(`mode: online` + `online_image_pull` / `mode: offline` + `offline_image_pull`).

Product source (`appliance-code` / `appliance-ctl`) is **not** under `deps/` —
this skill's workspace sync provides local trees; with `OFFLINE_BUILD=1` or
`USE_LOCAL_CHECKOUTS=1`, packaging uses those trees without fetching remotes.

See [docs/offline-build-deps.md](../../../docs/offline-build-deps.md).


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
- `--install-config` → clean uninstall (if zonctl present) → public fresh
  install → optional bootstrap → target/client verify → report

**Reinstall policy (current):** no in-place upgrade on the public/lab path.
Always `zonctl uninstall --confirm yes` then fresh install. Config-preserving
upgrade is parked.

Secrets stay in the Mac shell as env vars **named** by config `*_env` keys
(`DEV_*`, `APPLIANCE_BUILD_SUDO_PASSWORD`, `APPLIANCE_TARGET_SUDO_PASSWORD`,
`APPLIANCE_FIRST_ADMIN_PASSWORD` when `install.bootstrap_admin` is true).

Important rules:

- use SSH aliases, not raw IPs when practical
- use absolute remote paths, not `~/...`
- do not store passwords in the config
- appliance state dir is product-fixed `/var/lib/zon/state` (not YAML)
- packaging defaults to **foundation + developer + inference**; set
  `build_flow.appliance_packs` to `all` (default), `foundation`, `foundation,developer`,
  or `foundation,inference`. Skill exports that as `APPLIANCE_PACKS` into product
  scripts. Publish follows `export/release-index.yaml`.
  `install.appliance_profile` only selects which published packs to download.

Publish/install download uses the appliance file API only:

- `https://$DEV_REGISTRY/api/v1/files/appliance/<version>/`
- token/TLS: `DEV_REGISTRY_TOKEN` / `DEV_REGISTRY_TLS_VERIFY`

## Scripts (e2e call graph)

**Product (repo `scripts/` — only supported build-host sequence)**

1. `scripts/bootstrap-build-host.sh`
2. `scripts/build-full-bundle.sh`
3. `scripts/publish-release.sh`

Also skill-owned post-build check:
`.agents/skills/release/scripts/validate-release-artifacts.py`
(release-input ↔ bundle OCI contract after the three product scripts).
Product-owned install helper: `scripts/install-release.sh`
(published with the release).

**Skill entry / remote wrappers**

- `scripts/run-release-from-devhost.sh` — only day-to-day e2e entry
- `scripts/run-build-and-publish-on-build-host.sh` — Mac: preflight, sync repo, scp config, inject env, SSH
- `scripts/build-and-publish.sh --local` — thin build-host worker: YAML → three product scripts → collect/validate

**Install path**

- `scripts/run-install-via-public-helper-on-target.sh` — Mac: curl published helper on target
- `scripts/bootstrap-admin-on-target.sh` / `bootstrap-default-license-on-target.sh` — optional
- `scripts/verify-target.sh` / `verify-client-access.sh` / `verify-artifact-access.py`

**Shared + report**

- `scripts/common.sh` / `scripts/config_query.py`
- `scripts/summarize-release-run.py`

## Workflow

1. On the build host with `DEV_*` exported, run the three product scripts above.
2. From the Mac, prefer `run-release-from-devhost.sh` with the three configs (same three product scripts remotely).
3. Do not invent a third packaging path.
