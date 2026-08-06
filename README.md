# appliance-release

Public packaging and distribution tooling for the Zon platform.

This repo assembles the final signed appliance bundle. `zonctl` source lives in
the sibling `appliance-ctl` repo; product artifacts such as the chart and
release-input handoff come from `appliance-code`.

## Main Commands

- `make verify`
  Local checks for this repo.
- `make build-and-publish`
  Build-host release sequence (bootstrap → build → publish). Prefer this
  for CI / Argo: inject `DEV_*`, `RELEASE_WORK_ROOT`, and optional
  `PRODUCT_VERSION` in the runner env; no script paths needed in the workflow.
  Equivalent leaf scripts (same sequence):
  1. `bash ./scripts/bootstrap-build-host.sh`
  2. `bash ./scripts/build-full-bundle.sh`
  3. `bash ./scripts/publish-release.sh`

The build flow exports:

- `appliance-<product-version>-bundle.tar.gz`
- `release-signing.pub`

## Build-Host Bootstrap

The Linux build machine needs a one-time bootstrap for `appliance-code`'s
Podman dev-container path:

```bash
export DEV_REGISTRY_USER=<github-username>
export DEV_REGISTRY_TOKEN=<PAT with read:packages>
bash ./scripts/bootstrap-build-host.sh
```

## Documentation By Machine / Use Case

- [Docs index](docs/README.md)
- [Developer guide](docs/developer-guide.md)
- [Manual bundle assembly](docs/manual-bundle-assembly.md)
- [Operator guide](docs/operator-guide.md)
- [Artifact registry](docs/artifact-registry.md)
- [LAN DNS](docs/lan-dns.md)
- [Security model](docs/security-model.md)
- [Architecture and boundaries](docs/architecture-and-boundaries.md)
- [Historical release plan](docs/archive/release-plan.md)
- [Third-party notices](NOTICES.md)
- [Changelog](CHANGELOG.md)
