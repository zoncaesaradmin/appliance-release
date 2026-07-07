# Third-Party Notices

## Direct Build Dependencies (this repository's Go code)

| Component | License | Used for |
| --- | --- | --- |
| [santhosh-tekuri/jsonschema](https://github.com/santhosh-tekuri/jsonschema) v5.3.1 | Apache License 2.0 | JSON Schema (draft 2020-12) validation for every schema in `schemas/` (`internal/manifest`) |

This is the only direct third-party Go module dependency; everything else
this repository's own code uses is the Go standard library. Run
`go list -m all` for the complete resolved module graph including
transitive dependencies.

## Third-Party Runtime Components (bundled at release time)

The complete air-gap bundle pins and includes these upstream components
(see "Third-Party Inputs" in [docs/release-plan.md](docs/release-plan.md)).
Their own notices, licenses, SBOMs, and provenance are collected into the
bundle's own `notices/`, `sbom/`, and `provenance/` directories at release
assembly time — that assembly pipeline (`R2-01` and later in the execution
ledger) is what will populate the per-artifact notices this file
currently only enumerates by category:

- **K3s** — binary, install script, and bundled platform images (including
  Traefik)
- **zot** — OCI registry, used as the product data-plane registry after
  rollout (never a bootstrap dependency)
- **Buildah, Skopeo, ORAS** — OCI build/copy/artifact tooling used during
  release assembly, not at install time
- **Syft, Grype** — SBOM generation and vulnerability scanning, plus the
  offline Grype vulnerability database

None of these are vendored into this Git repository; they are acquired,
verified, and packaged into release-only artifact storage, per
"Large archives and generated OCI payloads are published as immutable
release assets... not committed to Git history" in the release plan.
