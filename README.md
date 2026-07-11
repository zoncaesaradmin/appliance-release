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
export REGISTRY_USER=<github-username>
export REGISTRY_TOKEN=<PAT with read:packages>
bash ./scripts/ci/bootstrap-build-host.sh
```

## Documentation By Machine / Use Case

### Developer Machine

- [Developer getting started](docs/getting-started.md)
- [Manual bundle assembly (advanced)](docs/real-setup.md)

### Build Machine / CI

- [Build machine CI workflow](docs/automation.md)

### Publish Server

- [HTTP publish workflow](docs/distribution-http.md)

### Target Device

- [Target host operations](docs/target-host-operations.md)

### Reference

- [Install reference](docs/install.md)
- [Upgrade reference](docs/upgrade.md)
- [Backup and restore reference](docs/backup-restore.md)
- [Troubleshooting reference](docs/troubleshooting.md)
- [Target host support matrix](docs/support-matrix.md)
- [Offline verification reference](docs/verification.md)
- [Security model](docs/security.md)
- [Release plan](docs/release-plan.md)
- [Third-party notices](NOTICES.md)
- [Changelog](CHANGELOG.md)
