#!/usr/bin/env python3
"""Tests for build-log artifact path detection (dir-only release-input)."""

from __future__ import annotations

import tempfile
from pathlib import Path

from detect_build_log_artifacts import detect_from_lines


def test_prefers_host_release_input_dir_over_container_path() -> None:
    with tempfile.TemporaryDirectory(prefix="detect-build-log-") as tmp_dir:
        tmp = Path(tmp_dir)
        host_dir = tmp / "release-input-0.1.0"
        host_dir.mkdir()
        (host_dir / "release-input.json").write_text("{}", encoding="utf-8")
        workspace_dir = tmp / "workspace-release-input"
        workspace_dir.mkdir()
        (workspace_dir / "release-input.json").write_text("{}", encoding="utf-8")

        log = f"""
skipped release-input tarball (--skip-tarball)
release-input directory:
  /workspace/.run/release-input-0.1.0
imported release-input into:
  {workspace_dir}
release-input tarball: skipped (dir assemble; set ARCHIVE_RELEASE_INPUT_WRITE_TARBALL=1 to write)

release-input directory:
  {host_dir}

final packs (foundation std-llm) TARGET_ARCH=amd64:
  {tmp}/out/appliance-0.1.0-foundation
  {tmp}/out/appliance-0.1.0-std-llm

exported customer delivery files:
  {tmp}/export/appliance-0.1.0-foundation-amd64.tar.gz
  {tmp}/export/appliance-0.1.0-std-llm-amd64.tar.gz
  {tmp}/export/release-index.yaml
""".strip().splitlines()

        detected = detect_from_lines(log)
        if detected["DETECTED_RELEASE_INPUT_DIR"] != str(host_dir):
            raise AssertionError(
                f"expected host release-input dir, got {detected['DETECTED_RELEASE_INPUT_DIR']!r}"
            )
        if detected["DETECTED_RELEASE_INPUT_TAR"]:
            raise AssertionError(
                f"expected empty tarball detection, got {detected['DETECTED_RELEASE_INPUT_TAR']!r}"
            )
        if detected["DETECTED_EXPORT_DIR"] != str(tmp / "export"):
            raise AssertionError(f"export dir = {detected['DETECTED_EXPORT_DIR']!r}")
        if "appliance-0.1.0-foundation" not in detected["DETECTED_PACK_DIRS"]:
            raise AssertionError(f"pack dirs = {detected['DETECTED_PACK_DIRS']!r}")


def test_falls_back_to_imported_release_input_when_host_summary_missing() -> None:
    with tempfile.TemporaryDirectory(prefix="detect-build-log-") as tmp_dir:
        tmp = Path(tmp_dir)
        workspace_dir = tmp / "workspace-release-input"
        workspace_dir.mkdir()
        (workspace_dir / "release-input.json").write_text("{}", encoding="utf-8")
        log = f"""
release-input directory:
  /workspace/.run/release-input-0.1.0
imported release-input into:
  {workspace_dir}
""".strip().splitlines()
        detected = detect_from_lines(log)
        if detected["DETECTED_RELEASE_INPUT_DIR"] != str(workspace_dir):
            raise AssertionError(
                f"expected imported release-input, got {detected['DETECTED_RELEASE_INPUT_DIR']!r}"
            )


def main() -> int:
    test_prefers_host_release_input_dir_over_container_path()
    test_falls_back_to_imported_release_input_when_host_summary_missing()
    print("test_detect_build_log_artifacts: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
