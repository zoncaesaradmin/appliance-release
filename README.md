# appliance-release

Public packaging and distribution tooling for the Zon platform.

This repo assembles the final signed appliance bundle. `zonctl` source lives in
the sibling `appliance-ctl` repo; product artifacts such as the chart and
release-input handoff come from `appliance-code`.

## Main Commands

- `make verify`
  Local checks for this repo.
- `bash ./scripts/ci/build-full-bundle.sh`
  Primary build-machine / CI entrypoint.
- `make publish-release ...`
  Copy exported release files to an HTTP/HTTPS download server.

The build flow exports:

- `appliance-<product-version>-bundle.tar.gz`
- `release-signing.pub`

## Build-Host Bootstrap

The Linux build machine needs a one-time bootstrap for `appliance-code`'s
Podman dev-container path:

```bash
export DEV_REGISTRY_USER=<github-username>
export DEV_REGISTRY_TOKEN=<PAT with read:packages>
bash ./scripts/ci/bootstrap-build-host.sh
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
