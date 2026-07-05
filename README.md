# appliance-release

Public packaging, installation, upgrade, recovery, and distribution tooling for the Zon platform (built from the private `appliance-code` product input). The CLI is `zonctl`.

Zon installs onto a supported Ubuntu Server host with one command, owning the complete Kubernetes (K3s) lifecycle so operators never touch K3s/Helm/Traefik directly. See [docs/release-plan.md](docs/release-plan.md) for the full plan.

The executable ownership and delivery plan is in [docs/release-plan.md](docs/release-plan.md).

This repository consumes signed, immutable product inputs. It does not contain or rebuild private application source.

## Documentation

- [Getting started (operators and developers)](docs/getting-started.md)
- [Installing Zon](docs/install.md)
- [Upgrading Zon](docs/upgrade.md)
- [Backup and restore](docs/backup-restore.md)
- [Security model](docs/security.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Support matrix](docs/support-matrix.md)
- [Offline verification guide](docs/verification.md)
- [Third-party notices](NOTICES.md)
- [Changelog](CHANGELOG.md)
