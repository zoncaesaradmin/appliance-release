# Appliance Release Script Usage

Okay these exports you enable first and then run the script with the three config
files:

```bash
export DEV_REGISTRY_USER=zoncaesaradmin
export DEV_REGISTRY_TOKEN='...'
export APPLIANCE_BUILD_SUDO_PASSWORD='caesar'
export APPLIANCE_TARGET_SUDO_PASSWORD='caesar'
export APPLIANCE_FIRST_ADMIN_PASSWORD='ins3965!'
```

Notes:

- Pass three configs explicitly:
  `--config` (Mac), `--build-publish-config`, `--install-config`.
  Start from `references/config.devhost.example.yaml`,
  `references/config.build-publish.example.yaml`, and
  `references/config.install.example.yaml` (see `references/config.example.yaml`
  for the overview). Scripts do **not** invent operational defaults — required
  keys must appear in their role file (fixed lab values are fine in YAML).
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
  fixed as `registry.local/dev-build`. The same `DEV_REGISTRY*` credentials
  also drive an automatic LAN OCI build-cache inside `build-full-bundle.sh`
  (`DEV_REGISTRY/build-cache/...`, short probe → upstream fallback →
  best-effort seed).
- Build packaging always pulls/packages from the network (or the automatic
  LAN build-cache flow above). Local build-host path inputs such as
  `*_image_archive_source`, `workflows.crds_dir_source`, and
  `host_packages_dir_source` are rejected.
  K3s binary/images are downloaded by `build-full-bundle` from the appliance
  files API (`https://$DEV_REGISTRY/api/v1/files/k3s/$K3S_VERSION/…`). Seed
  that path once with `RELEASE_WORK_ROOT=<remote_build_root> scripts/fetch-k3s-inputs.sh`
  (stages under `$RELEASE_WORK_ROOT/inputs/`, then uploads).
- Do **not** put a `build_flow.product_publish` block in config. Signed-bundle
  distribution is the fixed product sequence
  `bootstrap-build-host.sh` → `build-full-bundle.sh` → `publish-release.sh`
  (DEV_REGISTRY file API). Service image push defaults live in appliance-code
  `build/service-image.mk` (`SERVICE_IMAGE_*` / `DEV_REGISTRY`).
- On the build host (product), that is the only sequence. The skill remotes the
  same three scripts. Bootstrap and build always use sudo via the skill
  (`APPLIANCE_BUILD_SUDO_PASSWORD`).
- `APPLIANCE_FIRST_ADMIN_PASSWORD` is used only when `install.bootstrap_admin` is
  true (first-admin bootstrap + Mac-side API verification).
- First-admin bootstrap and client verify are **off by default** in the example
  config (`install.bootstrap_admin: false`). Set `install.bootstrap_admin: true` to
  run them. Username comes from `install.bootstrap_admin_username`; password
  from `APPLIANCE_FIRST_ADMIN_PASSWORD`.
- Default/base license accept is also **off by default**. Set
  `install.enable_default_license: true` to accept the base/free entitlement after
  install (stage `bootstrapDefaultLicense`). Without that, licensing stays
  unresolved until an admin imports a license or accepts base entitlement in
  the UI. Install never requires a license file or online entitlement checks.
- Set `install.appliance_profile` in the config, or omit it to default to `core`.
  Profile is **install-time only**: it selects which modules are activated on
  the target. Packaging always produces the complete product super-set (workflows engine,
  Artifact Server, DNS, host-packages for mdns+wifi-ap, workspace-provisioner, dev-build).
- Day-to-day entry is `run-release-from-devhost.sh` with only
  `--config`, `--build-publish-config`, and `--install-config`. Stage selection
  is by which paths you pass (no `build_flow.skip` / `install.skip`). After
  public install, `install.bootstrap_admin` / `install.enable_default_license`
  and verify stages run; `report.final_ok` prints `OK run`.
- Host mDNS and Wi-Fi AP packages are always in the signed bundle and staged
  at install; enable them day-2 via Admin UI/API after first admin login (not
  via install config flags).
- Set `install.appliance_name` and `install.dns_zone` (both required). The
  installer derives the FQDN as `<appliance_name>.<dns_zone>` for TLS,
  `canonicalOrigin`, and the registry realm. There is no separate `public_host`
  override.
- Control-plane **namespace** and **deployment name** are product-fixed, not
  install YAML: namespace `control` (`zonctl` `defaultChartNamespace`) and
  deployment `api-server` (chart `appliance-control-plane` fullname /
  `app.kubernetes.io/name`). Do not set `install.kubernetes_namespace` or
  `install.control_plane_deployment` (rejected). Bootstrap scripts use the
  same constants.
- Release-side install helpers also add the target host's current
  `hostname.local` as an extra TLS SAN automatically, so the existing host
  name can be used for mDNS-friendly lab access without changing
  `install.appliance_name`.
- Optional `install.image_pull_registry` teaches K3s/containerd to pull from a
  private LAN registry (`registries.yaml`). Bundle preload stays primary.
  Typical shape reuses the same env names as `dev_image_pull`:
  `registry_env: DEV_REGISTRY`, `username_env: DEV_REGISTRY_USER`,
  `token_env: DEV_REGISTRY_TOKEN`, `tls_verify_env: DEV_REGISTRY_TLS_VERIFY`.
  Do not set literal `install.image_pull_registry.registry` (rejected).
  Omit the block for preload-only.
- Publish always uses the appliance file API on `DEV_REGISTRY`
  (`https://$DEV_REGISTRY/api/v1/files/appliance/<version>/`). Token/TLS reuse
  `DEV_REGISTRY_TOKEN` / `DEV_REGISTRY_TLS_VERIFY`. Optional config overrides:
  `registry_env`, `token_env`, `tls_verify_env`, `files_path`, or a `base_url`
  that already ends in the files path. `static_http` / SSH publish was removed.
- For advanced extra SANs beyond the derived FQDN and the automatic
  `hostname.local` SAN, use `install.additional_tls_sans_csv` in the config.
- For builder* profiles (`builder`, `builder-landns`, `builder-storage-landns`),
  set `install.build_catalog_path` to an appliance-native catalog (see
  `build-catalog.example.yaml`). The public install helper copies that file to
  the target and stamps `BUILD_CATALOG_PATH` into `install-http-release.sh` so
  `zonctl install --build-catalog` injects `config.buildCatalog`. Without it,
  Helm rejects the chart default `buildCatalog: {}`. The catalog must declare
  `workProfiles` and HTTPS `repos`; never put private keys or tokens in it.
- If the build catalog references a workspace provisioner image, ensure
  `build_flow.dev_image_pull` is configured so `registry.local/dev-build`
  is bundled and preloaded on the target.
- The bundle flow always packages the complete offline host package super-set
  (`mdns` + `wifi-ap` capabilities) by exporting debs on the build host for the
  selected OS baseline (`ubuntu/24.04/amd64/*.deb`, etc.). The signed tree is
  `host-packages/`; zonctl stages packages at install; enable mDNS / Wi-Fi AP
  day-2 via Admin UI/API.
- Builder workflow repo URLs must use HTTPS.

## 1. Full Flow

Use this for the normal end-to-end workflow. CLI options are the three config
paths only; stage switches sit next to the stage they control.

```bash
/Users/zoncaesar/ws/appliance-release/.agents/skills/release/scripts/run-release-from-devhost.sh \
  --config /abs/path/to/lab-devhost.yaml \
  --build-publish-config /abs/path/to/lab-build-publish.yaml \
  --install-config /abs/path/to/lab-install.yaml
```

Minimal lab day-to-day switches (spread across the three files):

```yaml
# lab-devhost.yaml
build_host: { alias: zonsys@… }
target_host: { alias: zonsys@… }
report:
  final_ok: true

# lab-build-publish.yaml (excerpt)
build_flow:
  skip: false
release:
  version: 0.1.0
# …release_workspace, bundle_store, full build_flow…

# lab-install.yaml (excerpt)
install:
  bootstrap_admin: true
  enable_default_license: true
  appliance_profile: storage-landns
```

See the three `references/config.*.example.yaml` files for the full schemas.

E2e install is always **uninstall (if zonctl present) then fresh install**.
In-place public upgrade is not used.

- **Step 1** `buildPublish` — build and publish on the build host
- **Step 2** `install` — install on the target host
- **Step 2b–2d** bootstrap admin (if `install.bootstrap_admin`), default license
  (if `install.enable_default_license`), target verify, client/API verify from the Mac
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

For development-time target debugging, set `install.preserve_failed_state: true`
to forward zonctl's explicit debug mode to the target. In that mode, failed
install/upgrade attempts are left in place for inspection instead of being
rolled back automatically.

## 2. Build And Publish Only

From the Mac (preferred):

```bash
bash .agents/skills/release/scripts/run-release-from-devhost.sh \
  --config /abs/path/to/lab-devhost.yaml \
  --build-publish-config /abs/path/to/lab-build-publish.yaml
```

On the build host with skill YAML (after repo sync / env export):

```bash
bash .agents/skills/release/scripts/build-and-publish.sh \
  --local \
  --build-publish-config ~/.config/appliance-release/build-publish.yaml \
  --release-version 0.1.0
```

Or run the product scripts directly (no skill YAML):

```bash
bash scripts/bootstrap-build-host.sh
bash scripts/build-full-bundle.sh
bash scripts/publish-release.sh
```

`build-and-publish.sh` is a thin local worker: resolve YAML → three product
scripts → collect/validate artifacts. It does not SSH and does not own
packaging pin defaults (those live in `scripts/build-full-bundle.sh`).

After copied release-input and bundle metadata are available, the worker
validates required product artifacts, workflows engine release artifacts, and
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
`registry.local/dev-build` must appear in digest-pinned `extraOCIImages[]`
evidence. Digests in config refs are advisory; the build derives the platform
manifest digest from each OCI archive. The validation log is written to
`.run/appliance-release/<timestamp>/logs/release-artifact-validation.json`.

## 3. Install On Target Only

Use this when the release is already published and you want only the install step.

```bash
/Users/zoncaesar/ws/appliance-release/.agents/skills/release/scripts/run-install-via-public-helper-on-target.sh \
  --config /abs/path/to/lab-devhost.yaml \
  --build-publish-config /abs/path/to/lab-build-publish.yaml \
  --install-config /abs/path/to/lab-install.yaml
```

This script:

- runs `zonctl uninstall --confirm yes` on the target when zonctl is present
  (lab clean reinstall; skips on a fresh host)
- preflights published helper/bundle/checksum URLs from the **target** (LAN DNS),
  not the Mac
- downloads the published package on the target with HTTP `curl` against
  the resolved bundle-store base URL (Mac only orchestrates SSH)
- fails closed if that URL's host resolves to the target itself
  (usually `/etc/hosts` from a prior install that reused the distributor name)
- verifies checksums
- extracts the bundle on the target host
- runs `zonctl preflight`
- runs `zonctl install` (fresh only; refuses owned appliance with a clear
  uninstall-then-reinstall message — no auto-upgrade)
- passes `--appliance-name` / `--dns-zone` so zonctl derives the FQDN used for
  TLS, canonical origin, and the registry realm
- automatically includes the target host's current `hostname.local` as an
  extra TLS SAN for mDNS-friendly access
- can include more DNS and IP certificate identities with repeatable
  `--tls-san` flags or `install.additional_tls_sans_csv`
- uses the first-admin password from env only for a fresh install bootstrap

## 4. Verify Target Only

Use this after install if you want only target-side verification.

```bash
/Users/zoncaesar/ws/appliance-release/.agents/skills/release/scripts/verify-target.sh \
  --config /abs/path/to/lab-devhost.yaml \
  --install-config /abs/path/to/lab-install.yaml \
  --build-publish-config /abs/path/to/lab-build-publish.yaml \
  --run-dir /abs/path/to/run-dir
```

This script checks:

- `zonctl status`
- `zonctl verify`
- pod health with `kubectl get pods -A`
- installed-state version info
- a smoke check from the target host itself
- the browser UI home route returning the expected appliance UI shell when `client_verification.base_url` or `verification.ui_home_command` is configured
- support bundle collection on failure

For workflow-capable profiles (`core` and `builder`), it also checks the
workflows engine by default, unless you explicitly disable
`verification.workflows.enabled`:

- `workflows` and `appliance-builds` namespaces
- core workflow CRDs
- the workflow controller deployment and pods

If `install.appliance_profile` is a build-capable profile (`builder`,
`builder-landns`, `builder-storage-landns`), it also checks that
`/api/v1/work-profiles` is not a 404 from the target. When
`client_verification.base_url` is set, a stale host in
`verification.builder.api_command` is rewritten to that base URL (same idea as
the localhost smoke-test rewrite). Override `verification.builder.enabled` or
`verification.builder.api_command` only when you need custom reachability
behavior.

## 5. Verify Client/API Only

Use this from the Mac if the appliance is already installed and reachable.

```bash
/Users/zoncaesar/ws/appliance-release/.agents/skills/release/scripts/verify-client-access.sh \
  --install-config /abs/path/to/lab-install.yaml \
  --run-dir /abs/path/to/run-dir
```

This script checks API access from the Mac against `client_verification.base_url`
(typically `https://<appliance_name>.<dns_zone>` for landns). The Mac usually
does **not** use the appliance as a recursive DNS server, so when
`run-release-from-devhost.sh` provides `target_host.alias` as `user@IPv4`,
client verify maps the FQDN with `curl --resolve` / a forced connect IP. You can
also set `client_verification.connect_ip` or pass `--connect-ip`.

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

## 6. Config Files

Start from the three role examples linked from:

```bash
.agents/skills/release/references/config.example.yaml
```

Day-to-day paths are usually home-dir copies such as `~/lab-devhost.yaml`,
`~/lab-build-publish.yaml`, and `~/lab-install.yaml` — not a single merged
repo config file.

For final builder-profile evidence, also start from these local templates and
replace every host, repo, image, and target path with your real product values:

```bash
.agents/skills/release/references/build-catalog.example.yaml
```

Do not use a global skill symlink here. The single place to look is the
repo-local skill path: `.agents/skills/release/scripts`.

## 7. Live Release Local Repo Preflight

`run-build-and-publish-on-build-host.sh` (and thus `run-release-from-devhost.sh`)
refuses to start a **live** remote build when a sibling checkout has uncommitted
changes that could affect what the remote git clone builds (repo `scripts/`,
product code, Makefiles, schemas, charts, etc.). The remote build clones
`origin/<ref>` and hard-resets, so those local edits are never used — the guard
exists so a dirty tree is not mistaken for “what got tested.”

Local-only dirt (for example under `docs/`, `.cursor/`, `.run/`, and the
locally executed `.agents/skills/release/` skill files) only logs a warning and
does not block. To force-continue with build-affecting dirty files (knowing the
remote will still ignore them):

```bash
APPLIANCE_RELEASE_ALLOW_DIRTY=1 \
  .agents/skills/release/scripts/run-release-from-devhost.sh \
  --config /abs/path/to/devhost.yaml \
  --build-publish-config /abs/path/to/build-publish.yaml \
  --install-config /abs/path/to/install.yaml
```

Unpushed commits ahead of `origin/<ref>` still fail closed; push those first.

## 8. Simplest Day-To-Day Usage

Most days, this is enough:

```bash
export DEV_REGISTRY_USER=zoncaesaradmin
export DEV_REGISTRY_TOKEN='...'
export APPLIANCE_BUILD_SUDO_PASSWORD='caesar'
export APPLIANCE_TARGET_SUDO_PASSWORD='caesar'
export APPLIANCE_FIRST_ADMIN_PASSWORD='ins3965!'

/Users/zoncaesar/ws/appliance-release/.agents/skills/release/scripts/run-release-from-devhost.sh \
  --config /Users/you/lab-devhost.yaml \
  --build-publish-config /Users/you/lab-build-publish.yaml \
  --install-config /Users/you/lab-install.yaml
```

Secrets stay in the Mac shell; role YAMLs hold only non-secret settings.
CLI options are only the three config paths. `report.final_ok: true` prints
`OK run` after verification succeeds.

Before the remote build starts, the live path checks the local
`appliance-release`, `appliance-code`, and `appliance-ctl` repos and fails
closed if any of them are dirty or ahead of the remote ref the build host will
clone. This prevents a long live run from silently building stale remote `main`
while local cross-repo fixes are only in the workspace.
