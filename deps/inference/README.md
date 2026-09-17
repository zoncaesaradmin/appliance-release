# inference

Mirrors the pinned Ollama runtime and vLLM bases into the LAN build
cache for `export-inference-runtime-image-archive.sh` / offline
`build-full-bundle`.

Online packaging pulls the corresponding pinned Docker Hub image (fully
qualified for podman).
Offline packaging remaps to this LAN build-cache ref after
`make seed-build-deps` (or `make -C deps/inference release`).

This dependency seed supplies Ollama for `std-llm` and the vLLM bases for
`acc-llm` (amd64 and arm64 pins). The selected engine for a given build follows
product `TARGET_ARCH`. All inputs are wrapped with the appliance inference
manager during packaging so the appliance lifecycle boundary is identical.
