# inference

Mirrors the pinned Ollama runtime and the **TARGET_ARCH-specific** vLLM
base into the LAN build cache for `export-inference-runtime-image-archive.sh`
/ offline `build-full-bundle`.

One `TARGET_ARCH` seeds only that architecture:

| `TARGET_ARCH` | Seeded images |
|---|---|
| `amd64` | `ollama`, `vllm-openai-cpu` (x86_64) |
| `arm64` | `ollama`, `vllm-openai` (arm64) |

```bash
TARGET_ARCH=amd64 make -C deps/inference release
TARGET_ARCH=arm64 make -C deps/inference release
```

Online packaging pulls the corresponding pinned Docker Hub image.
Offline packaging remaps to this LAN build-cache ref after
`TARGET_ARCH=… make seed-build-deps`.
