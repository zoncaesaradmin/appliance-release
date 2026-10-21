# postgresql

Seeds the pinned PostgreSQL image used by the appliance control plane.

`build-cache/postgres:16.15-alpine3.24-${TARGET_ARCH}` is the only offline
source. Release assembly re-exports it into the signed bundle and derives the
runtime digest from the exported OCI archive.
