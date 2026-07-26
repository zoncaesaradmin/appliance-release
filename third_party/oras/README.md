# ORAS packaging note

`scripts/ci/build-full-bundle.sh` runs `scripts/publish/oras-bootstrap.sh` on
the **build host** and packages a pinned linux/amd64 ORAS CLI into:

- `<bundle>/tools/oras`
- `$EXPORT_DIR/tools/oras`

OCI publish uses the export copy. OCI install copies that export binary from
the build host onto the target before `oras pull`.
