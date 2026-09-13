# inference

Mirrors the pinned Ollama runtime into
`$DEV_REGISTRY/build-cache/ollama:0.6.5` for
`export-inference-runtime-image-archive.sh` / offline `build-full-bundle`.

Online packaging pulls `docker.io/ollama/ollama:0.6.5` (fully qualified for podman).
Offline packaging remaps to this LAN build-cache ref after
`make seed-build-deps` (or `make -C deps/inference release`).

This dependency seed supplies the pinned Ollama input for the `std-llm-amd64` delivery
package (`inference` capability). The seed directory and LAN cache reference
remain unchanged; the product chart disables GPU visibility for CPU execution.
It does not provide the future `acc-llm-arm64` package.
