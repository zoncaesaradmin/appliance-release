#!/usr/bin/env python3
"""Regression: OCI :bundled relabel must no-op when already annotated."""

from __future__ import annotations

import io
import json
import subprocess
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "build-full-bundle.sh"


def extract_relabel_function() -> str:
    text = SCRIPT.read_text(encoding="utf-8")
    start = text.index("relabel_oci_archive_reference() {")
    end = text.index("\nvalidate_bundled_oci_archive_reference()", start)
    return text[start:end]


def make_archive(path: Path, annotation: str) -> None:
    index = {
        "schemaVersion": 2,
        "manifests": [
            {
                "mediaType": "application/vnd.oci.image.manifest.v1+json",
                "digest": "sha256:" + ("a" * 64),
                "size": 12,
                "annotations": {"org.opencontainers.image.ref.name": annotation},
            }
        ],
    }
    with tarfile.open(path, "w") as tar:
        payload = b"hello-blob"
        info = tarfile.TarInfo(name="blobs/sha256/" + ("b" * 64))
        info.size = len(payload)
        tar.addfile(info, io.BytesIO(payload))
        index_bytes = json.dumps(index).encode("utf-8")
        index_info = tarfile.TarInfo(name="index.json")
        index_info.size = len(index_bytes)
        tar.addfile(index_info, io.BytesIO(index_bytes))
        layout = b'{"imageLayoutVersion":"1.0.0"}'
        layout_info = tarfile.TarInfo(name="oci-layout")
        layout_info.size = len(layout)
        tar.addfile(layout_info, io.BytesIO(layout))


def archive_mtime(path: Path) -> float:
    return path.stat().st_mtime


def main() -> None:
    fn = extract_relabel_function()
    with tempfile.TemporaryDirectory() as tmp:
        archive = Path(tmp) / "image.oci.tar"
        make_archive(archive, "registry.local/demo:bundled")
        before = archive.read_bytes()
        mtime_before = archive_mtime(archive)

        script = f"""#!/usr/bin/env bash
set -euo pipefail
{fn}
relabel_oci_archive_reference {archive!s} registry.local/demo:bundled
"""
        # Quote path for bash
        script = script.replace(str(archive), f"'{archive}'")
        runner = Path(tmp) / "run.sh"
        runner.write_text(script, encoding="utf-8")
        runner.chmod(0o755)
        subprocess.check_call(["bash", str(runner)])

        after = archive.read_bytes()
        if after != before:
            raise AssertionError("noop relabel rewrote an already-bundled OCI archive")
        if archive_mtime(archive) < mtime_before:
            raise AssertionError("noop relabel unexpectedly changed mtime backwards")

        # Changing the annotation must rewrite.
        make_archive(archive, "registry.local/demo:old")
        before2 = archive.read_bytes()
        script2 = f"""#!/usr/bin/env bash
set -euo pipefail
{fn}
relabel_oci_archive_reference '{archive}' registry.local/demo:bundled
"""
        runner.write_text(script2, encoding="utf-8")
        subprocess.check_call(["bash", str(runner)])
        after2 = archive.read_bytes()
        if after2 == before2:
            raise AssertionError("relabel did not rewrite when annotation differed")

    print("test-oci-relabel-noop: ok")


if __name__ == "__main__":
    main()
