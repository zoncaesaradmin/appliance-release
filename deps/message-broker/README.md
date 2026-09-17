# message-broker

The upstream image is pinned with its fully qualified Docker Hub name so
Podman does not depend on host-specific short-name aliases.

Seeds the pinned NATS image used by the always-on appliance JetStream message
broker. LAN tags are **arch-suffixed** so amd64 and arm64 seeds do not overwrite
each other:

`build-cache/nats:2.10.26-alpine-${TARGET_ARCH}`

Offline release builds consume that LAN reference; online builds use the same
upstream pin through the shared packaging path.

```bash
TARGET_ARCH=amd64 make -C deps/message-broker release
TARGET_ARCH=arm64 make -C deps/message-broker release
```
