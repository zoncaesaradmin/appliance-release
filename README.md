# appliance-release

Public packaging and distribution tooling for the Zon platform.

Zon installs onto a supported Ubuntu Server host with one command, owning the complete Kubernetes (K3s) lifecycle so operators never touch K3s/Helm/Traefik directly. See [docs/release-plan.md](docs/release-plan.md) for the full plan.

The executable ownership and delivery plan is in [docs/release-plan.md](docs/release-plan.md).

This repo no longer owns the `zonctl` source tree. `zonctl` now lives in
the sibling `appliance-ctl` repo, and this repo consumes the built CLI
binary while assembling a product bundle.

The primary bundle automation lives here:

- `make verify` runs the local pre-commit checks for this repo
- `bash ./scripts/ci/run-product-bundle.sh ...` is the single full CI workflow that uses this repo as the driver, clones `appliance-ctl`, writes the env file, and builds the bundle from a prepared `release-input` artifact
- `make ci-product-bundle ...` is the single CAE/CI entrypoint for a real bundle build
- `make product-bundle CONFIG=/abs/path/to/product-bundle.env` runs the real config-driven flow
- `make product-bundle CONFIG=$(pwd)/configs/product-bundle.sample.env` runs the sample end-to-end smoke flow with generated placeholder inputs

Repo-source defaults for the CI bootstrap script live in
[configs/ci-bootstrap.defaults.env](/Users/zoncaesar/ws/appliance-release/configs/ci-bootstrap.defaults.env).

That flow consumes the prepared product-side `release-input` handoff,
builds the external `zonctl` binary from `appliance-ctl`, stages the
K3s-side artifacts, assembles the final signed bundle, and verifies it.

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
