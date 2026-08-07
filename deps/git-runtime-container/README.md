# git-runtime-container

Mirrors a pinned `docker.io/alpine/git` image into
`$DEV_REGISTRY/build-cache/alpine-git:<tag>`.

Product packaging re-exports that seed as `registry.local/workspace-provisioner`
for workspace-prepare workflow pods (git clone / prepare). Kept separate from
`development-container` so the appliance does not preload the fat `dev-build`
toolchain for that role.
