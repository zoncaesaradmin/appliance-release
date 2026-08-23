# video

Mirrors the pinned Jellyfin runtime into
`$DEV_REGISTRY/build-cache/jellyfin:10.10.7` for
`export-video-runtime-image-archive.sh` / offline `build-full-bundle`.

Online packaging pulls `docker.io/jellyfin/jellyfin:10.10.7` (fully qualified for podman).
Offline packaging remaps to this LAN build-cache ref after
`make seed-build-deps` (or `make -C deps/video release`).
