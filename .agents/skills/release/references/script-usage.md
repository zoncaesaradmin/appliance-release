# Appliance Release Script Usage

Okay these exports you enable first and then run the script:

```bash
export APPLIANCE_RELEASE_CONFIG=/Users/zoncaesar/ws/appliance-release/appliance-release.config.yaml
export DEV_REGISTRY_USER=zoncaesaradmin
export DEV_REGISTRY_TOKEN='...'
export APPLIANCE_BUILD_SUDO_PASSWORD='caesar'
export APPLIANCE_TARGET_SUDO_PASSWORD='caesar'
export APPLIANCE_FIRST_ADMIN_PASSWORD='ins3965!'
```

Notes:

- `APPLIANCE_RELEASE_CONFIG` is the main common input for all scripts.
- Start from `references/config.example.yaml`: one file with **BUILD / PUBLISH**
  then **INSTALL / VERIFY** sections. Scripts do **not** invent operational
  defaults — every required key must be present in the config (fixed lab values
  are fine in YAML). See the example for `release_path_prefix`,
  `build_command` / `publish_command`, `bundle_download_dir`, verification
  commands, and capability flags.
- If `APPLIANCE_RELEASE_CONFIG` is set, you usually do not need `--config`.
- Pull credentials for the dev container image are named by
  `build_flow.dev_image_pull.username_env` /
  `build_flow.dev_image_pull.token_env` and must be exported in the shell
  (for example `DEV_REGISTRY_USER` / `DEV_REGISTRY_TOKEN`).
- Pull TLS verification is also named by
  `build_flow.dev_image_pull.tls_verify_env` and must resolve to `true` or
  `false` in the shell.
- Set `build_flow.dev_image_pull` (registry/repo/name env names, `image_tag`,
  username/token/TLS env names). That block is only for pulling the
  development-container used as build tooling. The bundled offline name is
  fixed as `registry.local/dev-build`.
- Do **not** put a `build_flow.product_publish` block in config. Signed-bundle
  distribution is `bundle_store` + `publish_command`. Service image push defaults
  live in appliance-code `build/service-image.mk` (`SERVICE_IMAGE_*` /
  `DEV_REGISTRY`).
- `APPLIANCE_FIRST_ADMIN_PASSWORD` is used both for install and Mac-side API verification.
- Set `install.appliance_profile` in the config (required).
- A `run-release-flow.sh --appliance-profile` override is forwarded to install,
  target verification, and client verification so all phases use the same
  effective profile.
- Set `install.appliance_name` and `install.dns_zone` (both required). The
  installer derives the FQDN as `<appliance_name>.<dns_zone>` for TLS,
  `canonicalOrigin`, and the registry realm. There is no separate `public_host`
  override.
- Optional `install.image_pull_registry` teaches K3s/containerd to pull from a
  private LAN registry (`registries.yaml`). Bundle preload stays primary.
  Typical shape reuses the same env names as `dev_image_pull`:
  `registry_env: DEV_REGISTRY`, `username_env: DEV_REGISTRY_USER`,
  `token_env: DEV_REGISTRY_TOKEN`, `tls_verify_env: DEV_REGISTRY_TLS_VERIFY`.
  Do not set literal `install.image_pull_registry.registry` (rejected).
  Omit the block for preload-only.
- Set `bundle_store.mode` to `static_http` or `appliance_files` (required):
  - `static_http` — publish/install via an external static HTTP server (`base_url`,
    `publish_server_alias`, `publish_remote_root`, `release_path_prefix`)
  - `appliance_files` — publish/install via the appliance-managed authenticated
    file API. `base_url` must be `https://<distributor-fqdn>/api/v1/files`
    (Traefik `/files` was removed). Set `bundle_store.access_token` to a
    long-lived API token from the distributor Dashboard → API tokens (prefer
    “Artifact files only” scopes). Set `bundle_store.tls_insecure` or
    `bundle_store.cacert_path` explicitly (no silent `-k`). Requires an
    already-installed artifact-capable distributor appliance (day-2 path).
- For advanced extra SANs beyond the derived FQDN, use
  `install.additional_tls_sans_csv` in the config.
- For the `builder` profile, set `install.build_catalog_path` or pass
  `--build-catalog PATH` when the bundle does not already include a
  `config.buildCatalog` value with workspace profiles, HTTPS repo URLs, and a
  digest-pinned workspace provisioner image. The file is copied to the target
  install temp dir and passed to `zonctl`; it should contain only product
  config, never private keys or tokens.
- If the build catalog references a workspace provisioner image, ensure
  `build_flow.dev_image_pull` is configured so `registry.local/dev-build`
  is bundled and preloaded on the target.
- Builder workflow repo URLs must use HTTPS.

## 1. Full Flow

Use this for the normal end-to-end workflow.

```bash
/Users/zoncaesar/ws/appliance-release/.agents/skills/release/scripts/run-release-flow.sh
```

Common explicit example:

```bash
/Users/zoncaesar/ws/appliance-release/.agents/skills/release/scripts/run-release-flow.sh \
  --release-version 0.1.0 \
  --appliance-profile builder \
  --build-catalog /Users/zoncaesar/ws/appliance-release/build-catalog.yaml \
  --preserve-failed-state \
  --uninstall-first \
  --final-ok
```

This does (stage banners print as `── stage <name>: …`):

- **Step 1** `buildPublish` — build and publish on the build host
- **Step 2** `install` — install on the target host
- **Step 2b–2d** bootstrap admin, target verify, client/API verify from the Mac
- **Step 3** `report` — summarize the run

One config file today; stages are ordered so build/publish and install/verify
can later use separate configs without rewriting the orchestrator.

- for the `builder` profile, verify builder REST route registration from the
  target and authenticated builder REST/MCP tool availability from the Mac
- write a final aggregate report to
  `.run/appliance-release/<timestamp>/metadata/release-report.json` and
  `.run/appliance-release/<timestamp>/release-report.md`

The wrapper writes the release-flow metadata and report on success and also
best-effort on phase failure, so failed runs should still leave a useful
handoff report in the run directory.

For development-time target debugging, add `--preserve-failed-state` to
forward zonctl's explicit debug mode to the target. In that mode, failed
install/upgrade attempts are left in place for inspection instead of being
rolled back automatically.

## 2. Build And Publish Only

Use this if you only want the remote build and publish step.

```bash
/Users/zoncaesar/ws/appliance-release/.agents/skills/release/scripts/build-and-publish.sh
```

Example with an explicit version:

```bash
/Users/zoncaesar/ws/appliance-release/.agents/skills/release/scripts/build-and-publish.sh \
  --release-version 0.1.0
```

Use this when:

- code is already pushed
- you want the build machine to pull, build, and publish
- you do not want to install yet

After copied release-input and bundle metadata are available, the script
validates required product artifacts, Argo release artifacts, and any
`extraOCIImages[]` entries against the final bundle manifest. Required runtime
checks include the control-plane image, the separate appliance UI image, and
the appliance Helm chart. For runtime OCI images, the copied release-input
`imageReference` must also match the final bundle manifest `imageReference`,
so the image imported on the target is the same image Helm will deploy.
The final bundle's `configuration/values.yaml` is also checked so
`image.repository/tag/digest` and `ui.image.repository/tag/digest` resolve to
those same control-plane and UI image references.
Required release-input evidence checks include the configuration schema,
compatibility metadata, checksums, SBOM, provenance, notices, and tests.
`registry.local/dev-build` (from `build_flow.dev_image_pull` settings)
must appear in digest-pinned `extraOCIImages[]` evidence. Digests in config
refs are advisory; the build derives the platform manifest digest from each
OCI archive. The validation log is written to
`.run/appliance-release/<timestamp>/logs/release-artifact-validation.json`.

## 3. Install On Target Only

Use this when the release is already published and you want only the install step.

```bash
/Users/zoncaesar/ws/appliance-release/.agents/skills/release/scripts/install-on-target.sh \
  --release-version 0.1.0 \
  --appliance-profile builder \
  --build-catalog /Users/zoncaesar/ws/appliance-release/build-catalog.yaml \
  --appliance-name registry1 \
  --dns-zone appliance.internal \
  --tls-san 192.168.1.101 \
  --preserve-failed-state \
  --uninstall-first
```

If you want to keep the current install and test without uninstalling first:

```bash
/Users/zoncaesar/ws/appliance-release/.agents/skills/release/scripts/install-on-target.sh \
  --release-version 0.1.0
```

This script:

- preflights published helper/bundle/checksum URLs from the **target** (LAN DNS),
  not the Mac
- downloads the published package on the target with HTTP `curl` against
  `bundle_store.base_url` (Mac only orchestrates SSH)
- fails closed if `bundle_store.base_url`'s host resolves to the target itself
  (usually `/etc/hosts` from a prior install that reused the distributor name)
- verifies checksums
- extracts the bundle on the target host
- runs `zonctl preflight`
- runs `zonctl install` on a fresh host
- automatically switches to `zonctl upgrade` when the target already has an owned appliance install
- passes `--appliance-name` / `--dns-zone` so zonctl derives the FQDN used for
  TLS, canonical origin, and the registry realm
- can include both DNS and IP certificate identities with repeatable
  `--tls-san` flags or `install.additional_tls_sans_csv`
- uses the first-admin password from env only for a fresh install bootstrap

## 4. Verify Target Only

Use this after install if you want only target-side verification.

```bash
/Users/zoncaesar/ws/appliance-release/.agents/skills/release/scripts/verify-target.sh
```

This script checks:

- `zonctl status`
- `zonctl verify`
- pod health with `kubectl get pods -A`
- installed-state version info
- a smoke check from the target host itself
- the browser UI home route returning the expected appliance UI shell when `client_verification.base_url` or `verification.ui_home_command` is configured
- support bundle collection on failure

For workflow-capable profiles (`core` and `builder`), it also checks Argo by
default, unless you explicitly disable `verification.argo.enabled`:

- `workflows` and `appliance-builds` namespaces
- core Argo Workflow CRDs
- the Argo controller deployment and pods

If `install.appliance_profile` is a build-capable profile (`builder`,
`builder-landns`, `builder-storage-landns`), it also checks that
`/api/v1/work-profiles` is not a 404 from the target. Override
`verification.builder.enabled` or `verification.builder.api_command` only when
you need custom reachability behavior.

## 5. Verify Client/API Only

Use this from the Mac if the appliance is already installed and reachable.

```bash
/Users/zoncaesar/ws/appliance-release/.agents/skills/release/scripts/verify-client-access.sh
```

This script checks:

- `POST /api/v1/auth/login`
- `GET /api/v1/auth/session`
- `GET /api/v1/users`
- for the `builder` profile, authenticated `GET /api/v1/work-profiles`
- for the `builder` profile, authenticated MCP `initialize` and `tools/list`
  with `submit_build` present
- for non-builder profiles, authenticated `GET /api/v1/work-profiles` returns
  `404` by default, proving build routes are not registered when the build
  capability is disabled
- for non-builder profiles, authenticated MCP `initialize` and `tools/list`
  succeed but the builder workflow tool names are absent by default
- for non-builder profiles, direct authenticated MCP `tools/call` for
  `submit_build` returns JSON-RPC tool-not-found, proving disabled build tools
  cannot be invoked by name
- when `client_verification.builder.workflow.enabled: true`, an actual
  REST-only builder workflow smoke: create workspace, list build targets,
  submit build, poll job status, fetch steps, and fetch logs
- for that workflow smoke, submit and job responses must both include the same
  non-empty `artifactRef`; this resolved image reference is copied into the
  final release report
- for that workflow smoke, a returned-evidence leak check that fails if job,
  step, or log output contains private-key markers
- writes a clear request log for each API call with method, full URL, sanitized headers, and sanitized POST body fields
- keeps the response body and response headers in separate log files

Notes about MCP access:

- `/mcp` is primarily intended for authenticated external MCP clients such as
  CLI tools, desktop clients, agent runtimes, and automation.
- Browser pages served from the appliance UI origin can call `/mcp`
  directly, but cross-origin browser tools are intentionally restricted by the
  control-plane origin check.
- A browser-based tool such as MCP Inspector should normally connect through
  its own local proxy instead of calling the appliance `/mcp` URL directly
  from a `localhost` page.

The real workflow smoke is intentionally opt-in because it runs a build. Use
it for final builder-profile evidence after the build catalog, Git host
reachability, builder image, and appliance registry are ready. For v1, set
`client_verification.builder.workflow.source_ref` to an immutable lowercase
40-character commit SHA; branch and tag resolution belongs in the control
plane/workflow layer later.

## 6. Config File

Start from:

```bash
/Users/zoncaesar/ws/appliance-release/.agents/skills/release/references/config.example.yaml
```

For final builder-profile evidence, also start from these local templates and
replace every host, repo, image, and target path with your real product values:

```bash
/Users/zoncaesar/ws/appliance-release/.agents/skills/release/references/build-catalog.example.yaml
```

Your usual real config lives in the repo, for example:

```bash
/Users/zoncaesar/ws/appliance-release/appliance-release.config.yaml
```

Do not use a global skill symlink here. The single place to look is the
repo-local skill path: `.agents/skills/release/scripts`.

## 7. Live Release Local Repo Preflight

`build-and-publish.sh` / `run-release-flow.sh` refuse to start a **live** remote
build when a sibling checkout has uncommitted changes that could affect what
the remote git clone builds (repo `scripts/`, product code, Makefiles, schemas,
charts, etc.). The remote build clones `origin/<ref>` and hard-resets, so those
local edits are never used — the guard exists so a dirty tree is not mistaken
for “what got tested.”

Local-only dirt (for example under `docs/`, `.cursor/`, `.run/`, and the
locally executed `.agents/skills/release/` skill files) only logs a warning and
does not block. To force-continue with build-affecting dirty files (knowing the
remote will still ignore them):

```bash
APPLIANCE_RELEASE_ALLOW_DIRTY=1 .agents/skills/release/scripts/run-release-flow.sh
```

Unpushed commits ahead of `origin/<ref>` still fail closed; push those first.

## 8. Local Milestone Verification

Before using the real build server or target host, run the non-live cross-repo
milestone gate from the release repo:

```bash
make verify-local-milestone
```

This runs the local release checks, appliance-code control-plane tests,
appliance-code control-plane chart tests, appliance-code UI tests,
appliance-code local e2e/profile-gating checks, and appliance-ctl tests. It
does not contact the real build server, publish server, or target host.
On success it writes a durable non-live evidence summary to
`.run/appliance-release/local-milestone-report.json`, including each checked
repo's git branch, HEAD commit, and dirty-worktree status. It also writes the
human-readable companion report
`.run/appliance-release/local-milestone-report.md`.

If your sibling repos are not next to `appliance-release`, override their
paths:

```bash
make verify-local-milestone \
  APPLIANCE_CODE_DIR=/abs/path/to/appliance-code \
  APPLIANCE_CTL_DIR=/abs/path/to/appliance-ctl
```

## 9. Advanced Final Profile Matrix

The main release workflow is still:

- `run-release-flow.sh` for a normal end-to-end run
- `make verify-local-milestone` for non-live cross-repo validation

If you need the stricter final profile-matrix planning, checklist, audit, and
readiness flow for final builder evidence, use the dedicated advanced guide:

```text
/Users/zoncaesar/ws/appliance-release/docs/internal/final-profile-matrix.md
```

## 10. Simplest Day-To-Day Usage

Most days, this is enough:

```bash
export APPLIANCE_RELEASE_CONFIG=/Users/zoncaesar/ws/appliance-release/appliance-release.config.yaml
export DEV_REGISTRY_USER=zoncaesaradmin
export DEV_REGISTRY_TOKEN='...'
export APPLIANCE_BUILD_SUDO_PASSWORD='caesar'
export APPLIANCE_TARGET_SUDO_PASSWORD='caesar'
export APPLIANCE_FIRST_ADMIN_PASSWORD='ins3965!'

/Users/zoncaesar/ws/appliance-release/.agents/skills/release/scripts/run-release-flow.sh --uninstall-first --final-ok
```

Before the remote build starts, the live wrapper now checks the local
`appliance-release`, `appliance-code`, and `appliance-ctl` repos and fails
closed if any of them are dirty or ahead of the remote ref the build host will
clone. This prevents a long live run from silently building stale remote `main`
while your local cross-repo fixes are still only in the workspace.
