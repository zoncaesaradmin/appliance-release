# dns

Mirrors the official `docker.io/coredns/coredns:1.14.4` image into
`$DEV_REGISTRY/build-cache/coredns:v1.14.4` for
`export-dns-server-image-archive.sh`. Online packaging pulls the same official
CoreDNS image directly; offline packaging consumes only this LAN mirror.
