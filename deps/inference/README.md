# inference

Mirrors the pinned Ollama runtime into
`$DEV_REGISTRY/build-cache/ollama:0.6.5` for
`export-inference-runtime-image-archive.sh` / offline `build-full-bundle`.

Online packaging pulls `ollama/ollama:0.6.5` from the public registry.
Offline packaging remaps to this LAN build-cache ref after
`make seed-build-deps` (or `make -C deps/inference release`).
