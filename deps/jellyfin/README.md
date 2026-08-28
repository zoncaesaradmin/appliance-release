# jellyfin

Mirrors the reviewed, digest-pinned Jellyfin Linux/amd64 runtime into
`$DEV_REGISTRY/build-cache/jellyfin:10.10.7-amd64`. The appliance bundle
re-exports that exact manifest as `registry.local/jellyfin@sha256:…`.

Online packaging reads the upstream digest from `pins.env`. Offline packaging
uses this LAN build-cache reference after `make seed-build-deps`; a missing
seed fails closed and never falls back to the public registry.
