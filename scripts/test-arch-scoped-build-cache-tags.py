#!/usr/bin/env python3
"""Fail closed if any OCI build-cache pin/remap omits an architecture scope.

LAN Artifact Server tags are single-arch. Sharing one tag across amd64/arm64
lets the last seed win and breaks cross-arch packaging (wrong-arch image →
buildah "image not known" / CrashLoop). Every arch-specific OCI seed must
encode TARGET_ARCH (or HOST_ARCH for compile-only bases) in the tag or name.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEPS = ROOT / "deps"
BUNDLE = ROOT / "scripts" / "build-full-bundle.sh"

# Packages that publish arch-specific OCI images into build-cache/.
# Exceptions:
#   - development-container: tags are already latest-<arch> / <ver>-<arch>
#   - jellyfin: amd64-only product; tag already ends in -amd64
#   - host-packages / platform-inputs: files API paths include TARGET_ARCH
#   - zot: arch is in the image *name* (zot-linux-${TARGET_ARCH})
REQUIRED_CACHE_TAG_BASE = {
    "dns": "CACHE_TAG_BASE",
    "message-broker": "CACHE_TAG_BASE",
    "git-runtime-container": "CACHE_TAG_BASE",
    "blob-storage": "CACHE_TAG_BASE",
    "workflows": "CACHE_TAG_BASE",
    "inference": "CACHE_TAG_BASE",  # ollama; vLLM tags already encode arch
}

REQUIRED_SERVICE_BUILD_BASES = (
    "GOLANG_CACHE_TAG_BASE",
    "NODE_CACHE_TAG_BASE",
    "ALPINE_CACHE_TAG_BASE",
    "UI_DEPS_CACHE_TAG_BASE",
)

REQUIRED_ARTIFACT_DEBIAN = "DEBIAN_CACHE_TAG_BASE"

# Offline remaps in build-full-bundle.sh must include ${TARGET_ARCH} or
# ${HOST_ARCH}, or already embed arch in the name/tag literal.
REQUIRED_LAN_CACHE_SNIPPETS = [
    'lan_cache_ref alpine-git "${ALPINE_GIT_CACHE_TAG_BASE}-${TARGET_ARCH}"',
    'lan_cache_ref nats "2.10.26-alpine-${TARGET_ARCH}"',
    'lan_cache_ref coredns "v${DNS_VERSION}-${TARGET_ARCH}"',
    'lan_cache_ref "${BLOB_STORAGE_CACHE_NAME}" "${BLOB_STORAGE_CACHE_TAG_BASE}-${TARGET_ARCH}"',
    'lan_cache_ref ollama "${INFERENCE_VERSION}-${TARGET_ARCH}"',
    'lan_cache_ref argoexec "${WORKFLOWS_VERSION}-${TARGET_ARCH}"',
    'lan_cache_ref workflow-controller "${WORKFLOWS_VERSION}-${TARGET_ARCH}"',
    'lan_cache_ref golang "1.26-${HOST_ARCH}"',
    'lan_cache_ref alpine-3.24.1-runtime "3.24.1-${TARGET_ARCH}"',
    'lan_cache_ref node "22-alpine-${HOST_ARCH}"',
    'lan_cache_ref controlplane-ui-web-deps "lockfile-${HOST_ARCH}"',
    'lan_cache_ref debian-bookworm-slim-runtime "bookworm-slim-${TARGET_ARCH}"',
    'lan_cache_ref "zot-linux-${TARGET_ARCH}"',
]


def fail(msg: str) -> None:
    print(f"test-arch-scoped-build-cache-tags: {msg}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    for pkg, key in REQUIRED_CACHE_TAG_BASE.items():
        pins = DEPS / pkg / "pins.env"
        text = pins.read_text(encoding="utf-8")
        if f"{key}=" not in text:
            fail(f"{pins}: missing {key}= (arch-suffixed seed tag base)")
        if re.search(r"(?m)^CACHE_TAG=", text):
            fail(f"{pins}: bare CACHE_TAG= is forbidden; use {key} + -${{TARGET_ARCH}}")

    sbb = (DEPS / "service-build-bases" / "pins.env").read_text(encoding="utf-8")
    for key in REQUIRED_SERVICE_BUILD_BASES:
        if f"{key}=" not in sbb:
            fail(f"service-build-bases/pins.env: missing {key}=")

    asb = (DEPS / "artifact-server-bases" / "pins.env").read_text(encoding="utf-8")
    if f"{REQUIRED_ARTIFACT_DEBIAN}=" not in asb:
        fail(f"artifact-server-bases/pins.env: missing {REQUIRED_ARTIFACT_DEBIAN}=")

    # Scripts must append TARGET_ARCH for every CACHE_TAG_BASE package.
    for pkg in REQUIRED_CACHE_TAG_BASE:
        for script_name in ("build.sh", "push.sh"):
            script = DEPS / pkg / "scripts" / script_name
            text = script.read_text(encoding="utf-8")
            if 'CACHE_TAG="${CACHE_TAG_BASE}-${TARGET_ARCH}"' not in text:
                fail(f"{script}: must set CACHE_TAG=\"${{CACHE_TAG_BASE}}-${{TARGET_ARCH}}\"")

    bundle = BUNDLE.read_text(encoding="utf-8")
    for snippet in REQUIRED_LAN_CACHE_SNIPPETS:
        if snippet not in bundle:
            fail(f"build-full-bundle.sh missing offline remap: {snippet}")

    # Forbid legacy non-arch offline remaps that used to collide.
    forbidden = [
        'lan_cache_ref alpine-git "${ALPINE_GIT_CACHE_TAG}"',
        'lan_cache_ref coredns "v${DNS_VERSION}"',
        'lan_cache_ref nats "2.10.26-alpine"',
        'lan_cache_ref ollama "${INFERENCE_VERSION}"',
        'lan_cache_ref argoexec "${WORKFLOWS_VERSION}"',
        'lan_cache_ref workflow-controller "${WORKFLOWS_VERSION}"',
        'lan_cache_ref debian-bookworm-slim-runtime bookworm-slim',
        'lan_cache_ref golang 1.26)',
        'lan_cache_ref golang "1.26"',
    ]
    for snippet in forbidden:
        if snippet in bundle:
            fail(f"build-full-bundle.sh still has non-arch-scoped remap: {snippet}")

    print("test-arch-scoped-build-cache-tags: ok")


if __name__ == "__main__":
    main()
