# Open WebUI source seed

This package seeds the exact reviewed Open WebUI git checkout used by the
patched appliance build. It deliberately does not mirror an upstream runtime
image: the appliance image is built from this source plus the numbered patches
in `appliance-code/services/open-webui`.

```sh
TARGET_ARCH=amd64 make -C deps/open-webui release
```

The source archive and checksum are uploaded through the appliance files API
under `build-deps/open-webui/<commit>/`. Online bundle assembly clones the same
tag and verifies its commit; offline assembly downloads only this seed and
fails closed when its checksum or commit differs. `TARGET_ARCH` is accepted for
the common seed interface even though this verified source checkout is arch
neutral.
