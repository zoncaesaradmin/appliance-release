# appliance-release

Public packaging and distribution tooling for the Zon platform.

Zon installs onto a supported Ubuntu Server host with one command, owning the complete Kubernetes (K3s) lifecycle so operators never touch K3s/Helm/Traefik directly. See [docs/release-plan.md](docs/release-plan.md) for the full plan.

The executable ownership and delivery plan is in [docs/release-plan.md](docs/release-plan.md).

This repo no longer owns the `zonctl` source tree. `zonctl` now lives in
the sibling `appliance-ctl` repo, and this repo consumes the built CLI
binary while assembling a product bundle.

The primary bundle automation lives here:

- `make verify` runs the local pre-commit checks for this repo
- `bash ./scripts/ci/build-full-bundle.sh` is the primary build-machine workflow; it uses this checked-out repo as the driver, clones only `appliance-code` and `appliance-ctl`, asks `appliance-code` to produce `release-input` from inside its dev container, and builds the final bundle
- `make product-bundle CONFIG=/abs/path/to/product-bundle.env` runs the real config-driven flow
- `make product-bundle CONFIG=$(pwd)/configs/product-bundle.sample.env` runs the sample end-to-end smoke flow with generated placeholder inputs

The single CI defaults file is
[configs/product-bundle.ci.env](/Users/zoncaesar/ws/appliance-release/configs/product-bundle.ci.env).

That flow consumes the prepared product-side `release-input` handoff,
builds the external `zonctl` binary from `appliance-ctl`, stages the
K3s-side artifacts, assembles the final signed bundle, verifies it, and
exports the two customer delivery files:

- `appliance-<product-version>-bundle.tar.gz`
- `release-signing.pub`

Rerunning the CI script is safe: it recreates the generated workspace,
artifacts, and exported delivery files from scratch each time, while the
dependency repo clones under the build root are reused and refreshed.

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
