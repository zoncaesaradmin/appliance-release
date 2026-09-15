# inference

Mirrors the pinned Ollama runtime and x86 CPU vLLM base into the LAN build
cache for `export-inference-runtime-image-archive.sh` / offline
`build-full-bundle`.

Online packaging pulls the corresponding pinned Docker Hub image (fully
qualified for podman).
Offline packaging remaps to this LAN build-cache ref after
`make seed-build-deps` (or `make -C deps/inference release`).

This dependency seed supplies Ollama for `std-llm-amd64`, the x86 CPU vLLM
base for `acc-llm-amd64`, and a pinned arm64 vLLM base for `acc-llm-arm64`.
All three inputs are wrapped with the appliance inference manager during
packaging, including Ollama, so the appliance lifecycle boundary is identical.
