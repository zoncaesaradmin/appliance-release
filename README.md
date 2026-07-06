# appliance-release

Public packaging and distribution tooling for the Zon platform.

Zon installs onto a supported Ubuntu Server host with one command, owning the complete Kubernetes (K3s) lifecycle so operators never touch K3s/Helm/Traefik directly. See [docs/release-plan.md](docs/release-plan.md) for the full plan.

The executable ownership and delivery plan is in [docs/release-plan.md](docs/release-plan.md).

This repo no longer owns the `zonctl` source tree. `zonctl` now lives in
the sibling `appliance-ctl` repo, and this repo consumes the built CLI
binary while assembling a product bundle.

The primary bundle automation lives here:

- `make verify` runs the local pre-commit checks for this repo
- `make product-bundle CONFIG=/abs/path/to/product-bundle.env` runs the real config-driven flow
- `make product-bundle CONFIG=$(pwd)/configs/product-bundle.sample.env` runs the sample end-to-end smoke flow with generated placeholder inputs

That flow uses the configured `appliance-code` and `appliance-ctl`
sources directly for local-path development inputs, or clones them when
you provide a remote URL or a pinned ref. It then builds the external
`zonctl` binary, packages the product-side handoff for the selected
version, stages the K3s-side artifacts, assembles the final signed
bundle, and verifies it.

## Documentation

- [Getting started (operators and developers)](docs/getting-started.md)
- [Automation and one-command bundle build](docs/automation.md)
- [Installing Zon](docs/install.md)
- [Real setup and bundle assembly](docs/real-setup.md)
- [Upgrading Zon](docs/upgrade.md)
- [Backup and restore](docs/backup-restore.md)
- [Security model](docs/security.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Support matrix](docs/support-matrix.md)
- [Offline verification guide](docs/verification.md)
- [Third-party notices](NOTICES.md)
- [Changelog](CHANGELOG.md)
