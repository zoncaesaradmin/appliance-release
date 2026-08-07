# Publishing inference model packs

Model packs are **not** assembled by `build-full-bundle.sh`. Publish them as
sibling artifacts next to a platform release.

## Steps

1. Build/export weights for the target runtime (v1 default: Ollama-compatible
   blob layout under `blobs/`).
2. Write `manifest.json` (`kind: appliance.modelpack/v1`) with
   `compatibility.inferenceVersion` matching the platform release.
3. Sign `manifest.json` → `manifest.json.sig` with the release-signing key.
4. Archive the pack directory and upload to the DEV_REGISTRY files API, e.g.
   `model-packs/<inferenceVersion>/<modelId>.tar.zst`.
5. Document digest, `modelId`, and `minRAMGB` in the release report.

Operator import on the target:

```bash
sudo zonctl models-import --bundle-dir /path/to/extracted-pack \
  --public-key /etc/zon/keys/release-signing.pub
```

See `appliance-code/docs/inference-model-packs.md` for the full contract and
the ~30 GB Qwen reference guidance.
