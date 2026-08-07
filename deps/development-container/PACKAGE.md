# development-container

Vendored copy of the appliance `dev-build` tooling image sources.

Publish path (unchanged from standalone development-container):

`$DEV_REGISTRY/$DEV_IMAGE_REPO/dev-build:$(VERSION)` and `:latest`

Default LAN example: `artifact-dns-1.appliance.internal/development-container/dev-build:latest`

## Commands

```bash
make build      # alias for build-dev
make test
make publish    # login + push-dev
make release    # build-dev + publish
```

Pins: [pins.env](pins.env). Full docs: [README.md](README.md) in this directory.
