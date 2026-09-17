#!/usr/bin/env python3
"""Parse build-full-bundle stdout for release-input / pack / export paths.

build-full-bundle (and archive-release-input inside the packaging container)
may emit the same labels more than once. Prefer the last path that exists on
the host so container paths like /workspace/.run/... are not selected over
the durable host release-input directory.
"""

from __future__ import annotations

import argparse
import shlex
from pathlib import Path


def collect_all_blocks(lines: list[str], label: str) -> list[str]:
    collected: list[str] = []
    capture = False
    current: list[str] = []
    for line in lines:
        if capture:
            if line.startswith("  "):
                value = line.strip()
                if value:
                    current.append(value)
                continue
            collected.extend(current)
            current = []
            capture = False
        if line.strip() == label:
            capture = True
            current = []
    if capture:
        collected.extend(current)
    return collected


def collect_final_pack_dirs(lines: list[str]) -> list[str]:
    pack_dirs: list[str] = []
    for index, line in enumerate(lines):
        if line.startswith("final packs (") and line.endswith(":"):
            pack_dirs = []
            for next_line in lines[index + 1 :]:
                if next_line.startswith("  "):
                    value = next_line.strip()
                    if value:
                        pack_dirs.append(value)
                    continue
                break
    return pack_dirs


def pick_existing(paths: list[str], *, require_release_input_json: bool = False) -> str:
    for path in reversed(paths):
        candidate = Path(path)
        if require_release_input_json:
            if candidate.is_dir() and (candidate / "release-input.json").is_file():
                return path
            continue
        if candidate.exists():
            return path
    # Do not return a non-existent path when a concrete on-disk check was
    # required; callers fall back to alternate labels (e.g. imported dir).
    if require_release_input_json:
        return ""
    return paths[-1] if paths else ""


def detect_from_lines(lines: list[str]) -> dict[str, str]:
    export_paths = collect_all_blocks(lines, "exported customer delivery files:")
    release_input_paths = collect_all_blocks(lines, "release-input tarball:")
    # Prefer the final host "release-input directory:" summary over earlier
    # container paths (/workspace/...) and over assemble's import target.
    release_input_dirs = collect_all_blocks(lines, "release-input directory:")
    release_input_dir = pick_existing(release_input_dirs, require_release_input_json=True)
    if not release_input_dir:
        imported_dirs = collect_all_blocks(lines, "imported release-input into:")
        release_input_dir = pick_existing(imported_dirs, require_release_input_json=True)
    bundle_paths = collect_all_blocks(lines, "final bundle:")
    pack_dirs = collect_final_pack_dirs(lines)

    export_dir = ""
    bundle_archive = ""
    for path in export_paths:
        candidate = Path(path)
        if not export_dir:
            export_dir = str(candidate.parent)
        name = candidate.name
        if name.endswith(".tar.gz") and "-foundation" in name and not bundle_archive:
            stem = name[: -len(".tar.gz")]
            if stem.endswith("-foundation") or "-foundation-" in stem:
                bundle_archive = path

    # Tarball lines may include the skip notice text; only keep real archives.
    release_input_tars = [
        path
        for path in release_input_paths
        if path.endswith((".tar.gz", ".tgz")) and not path.startswith("(")
    ]

    return {
        "DETECTED_RELEASE_INPUT_TAR": pick_existing(release_input_tars),
        "DETECTED_RELEASE_INPUT_DIR": release_input_dir,
        "DETECTED_BUNDLE_DIR": pick_existing(bundle_paths),
        "DETECTED_EXPORT_DIR": export_dir,
        "DETECTED_BUNDLE_ARCHIVE": bundle_archive,
        "DETECTED_PACK_DIRS": " ".join(pack_dirs),
    }


def detect_from_log(log_path: Path) -> dict[str, str]:
    lines = log_path.read_text(encoding="utf-8").splitlines()
    return detect_from_lines(lines)


def emit_shell(values: dict[str, str]) -> None:
    for name, value in values.items():
        print(f"{name}={shlex.quote(value)}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_log", type=Path, help="Path to build.log")
    args = parser.parse_args()
    emit_shell(detect_from_log(args.build_log))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
