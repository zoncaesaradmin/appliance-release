# jellyfin

Mirrors the reviewed, digest-pinned Jellyfin Linux/amd64 runtime into
`$DEV_REGISTRY/build-cache/jellyfin:10.10.7-amd64`. The appliance bundle
re-exports it as the digest-pinned canonical OCI manifest declared in
`pins.env` under `RUNTIME_REFERENCE`.

This seed is **amd64-only**. `TARGET_ARCH=amd64 make -C deps/jellyfin release`
mirrors and publishes; `TARGET_ARCH=arm64` skips (no arm64 pin).

Online packaging reads the upstream digest from `pins.env`. Offline packaging
uses this LAN build-cache reference after `TARGET_ARCH=amd64 make seed-build-deps`;
a missing seed fails closed and never falls back to the public registry.
