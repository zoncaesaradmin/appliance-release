# postgis

Seeds the pinned PostGIS image used by the Geo Zone profile.

The offline build consumes only
`build-cache/postgis:16-3.7-${TARGET_ARCH}` and the release bundle carries
the resulting image under the immutable `registry.local/postgis@sha256:...`
reference.
