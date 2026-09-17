# dns

Mirrors the official `docker.io/coredns/coredns:1.14.4` image into an
**arch-suffixed** LAN tag so amd64 and arm64 seeds do not collide:

`$DEV_REGISTRY/build-cache/coredns:v1.14.4-${TARGET_ARCH}`

Offline packaging consumes that mirror; online packaging pulls the same
official CoreDNS pin directly.

```bash
TARGET_ARCH=amd64 make -C deps/dns release
TARGET_ARCH=arm64 make -C deps/dns release
```
