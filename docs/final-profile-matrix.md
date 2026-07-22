# Final Profile Matrix

Use this guide only for the stricter final-release evidence flow across the
`core`, `storage`, and `builder` appliance profiles. It is intentionally kept
out of the normal day-to-day script usage path.

## 1. Final Input Checklist

If you are not sure whether the current config has all final builder-profile
inputs yet, generate the non-failing final input checklist first:

```bash
make final-profile-input-checklist \
  CONFIG=/Users/zoncaesar/ws/appliance-release/appliance-release.config.yaml
```

This target uses the same strict validation rules as
`plan-final-profile-matrix` but always exits successfully after writing:

```text
.run/appliance-release/final-profile-input-checklist.json
.run/appliance-release/final-profile-input-checklist.md
```

Use this checklist to fill the builder build catalog, immutable workflow
source ref, workflow target names, and any builder image bundle inputs before
switching to the fail-closed final plan.
The checklist also includes a secret-free YAML overlay template that can be
copied into your real config after replacing placeholder paths, image digests,
repo names, target names, and the workflow commit SHA.
The canonical example inputs live at:

- `.agents/skills/release/references/build-catalog.example.yaml`

Copy those into your own local working files before a real final builder run.
The suggested overlay in the checklist points at the example files so there is
only one canonical place to start from.

When required inputs are missing, the checklist intentionally omits runnable
profile-matrix commands and tells you not to run the live matrix from that
artifact. Only `final-profile-matrix-plan.md` is the executable final command
plan.

## 2. Final Plan

Before asking Codex to run the real appliance profile matrix, generate the
strict final command plan locally:

```bash
make plan-final-profile-matrix \
  CONFIG=/Users/zoncaesar/ws/appliance-release/appliance-release.config.yaml
```

This target fails closed unless final builder workflow evidence inputs are
configured, including the builder workflow smoke and build catalog. It writes:

```text
.run/appliance-release/final-profile-matrix-plan.json
.run/appliance-release/final-profile-matrix-plan.md
```

Equivalent direct command:

```bash
python3 /Users/zoncaesar/ws/appliance-release/.agents/skills/release/scripts/plan-profile-matrix.py \
  --config /Users/zoncaesar/ws/appliance-release/appliance-release.config.yaml \
  --require-builder-workflow \
  --output-json /Users/zoncaesar/ws/appliance-release/.run/appliance-release/final-profile-matrix-plan.json \
  --output-md /Users/zoncaesar/ws/appliance-release/.run/appliance-release/final-profile-matrix-plan.md
```

For non-final dry-run planning only, use:

```bash
make plan-profile-matrix \
  CONFIG=/Users/zoncaesar/ws/appliance-release/appliance-release.config.yaml
```

This does not contact the build server or target host. It validates that final
builder workflow evidence inputs are present. When
`install.build_catalog_path` is set, the planner checks that workspace profiles
and HTTPS repos are declared. The generic workspace provisioner image is an
appliance-owned bundle input, not a user catalog field; the build script
packages a digest-pinned Alpine Git image by default unless overridden through
`build_flow.workspace_provisioner_image_*` settings. Build targets are optional
and are validated only when present. The optional real workflow smoke cross-checks the
workspace profile (`work_profile`) and `repo` against catalog `workProfiles`
and `repos`; if build targets are present, `target_name` may use either a build
target name or one of its aliases.

The plan also fixes the capability evidence matrix:

- `core`: artifact routes and build routes absent.
- `storage`: zot/artifact checks positive; build/workflow routes absent.
- `builder`: both zot/artifact and build/workflow checks positive.

Artifact-positive runs require zot Deployment/PVC readiness, a `/v2/` bearer
challenge, API-token-to-registry-token issuance, filtered catalog access, and
anonymous, denied-scope, malformed-token, and revoked-token evidence. Optional
`client_verification.artifact.oci_smoke_command`,
`oras_smoke_command`, and `offline_smoke_command` checks are required to pass
when configured. They receive registry credentials only through process-local
environment variables and must not print them.

## 3. Final Audit

After the real runs finish, audit their generated reports locally:

```bash
make audit-final-profile-matrix \
  CORE_RUN_DIR=/Users/zoncaesar/ws/appliance-release/.run/appliance-release/<core-run-id> \
  STORAGE_RUN_DIR=/Users/zoncaesar/ws/appliance-release/.run/appliance-release/<storage-run-id> \
  BUILDER_RUN_DIR=/Users/zoncaesar/ws/appliance-release/.run/appliance-release/<builder-run-id>
```

This defaults to
`.run/appliance-release/final-profile-matrix-plan.json`, always requires the
builder workflow smoke evidence, and writes
`.run/appliance-release/final-profile-matrix-audit.json`.

Equivalent direct command:

```bash
python3 /Users/zoncaesar/ws/appliance-release/.agents/skills/release/scripts/audit-profile-matrix-reports.py \
  --core-run-dir /Users/zoncaesar/ws/appliance-release/.run/appliance-release/<core-run-id> \
  --storage-run-dir /Users/zoncaesar/ws/appliance-release/.run/appliance-release/<storage-run-id> \
  --builder-run-dir /Users/zoncaesar/ws/appliance-release/.run/appliance-release/<builder-run-id> \
  --plan-json /Users/zoncaesar/ws/appliance-release/.run/appliance-release/final-profile-matrix-plan.json \
  --require-builder-workflow \
  --output-json /Users/zoncaesar/ws/appliance-release/.run/appliance-release/final-profile-matrix-audit.json
```

This checks each `metadata/release-report.json` for successful unskipped
steps, matching profile names, disabled builder REST/MCP evidence for `core`
and `storage`, builder MCP tool evidence for `builder`, and final workflow
smoke evidence when `--require-builder-workflow` is set. It additionally
enforces the artifact capability matrix and configured OCI/ORAS/offline smoke
results. When `--plan-json` is
provided, it also verifies the audited reports match the generated plan's
profile list, release version, builder-workflow requirement, and expected
builder build-catalog/source-credential manifest paths.

## 4. Final Readiness

After the strict final audit, write the final readiness summary:

```bash
make final-readiness-report
```

This reads the local milestone report, strict final profile-matrix plan, and
strict final profile-matrix audit. If
`.run/appliance-release/final-profile-input-checklist.json` exists, it also
summarizes whether final builder inputs are ready and copies any checklist
validation errors into the readiness Markdown so the handoff report is
self-contained. It writes:

```text
.run/appliance-release/final-readiness-report.json
.run/appliance-release/final-readiness-report.md
```

The status is `ready` only when all required local and live evidence exists and
the final audit passed with builder workflow evidence required. When the status
is `not_ready`, the report includes the next commands to run.

To fail closed unless the release is fully ready, run:

```bash
make assert-final-readiness
```
