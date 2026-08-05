#!/usr/bin/env python3
"""Merge devhost + build/publish + install release configs into one document.

Used by run-release-flow.sh so stage workers keep a single --config input
while operators edit three role-scoped files.

Rules:
- Each input is loadable with config_query (simple YAML or JSON).
- Top-level keys must only appear in the role-allowed set for that file.
- Nested merges recurse; a key path must not be defined in more than one input.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from config_query import load_config  # noqa: E402

DEVHOST_TOP_LEVEL = frozenset({"build_host", "target_host", "report"})
BUILD_PUBLISH_TOP_LEVEL = frozenset({"release_workspace", "release", "build_flow", "bundle_store"})
INSTALL_TOP_LEVEL = frozenset({"install", "verification", "client_verification"})

ROLE_ALLOWED = {
    "devhost": DEVHOST_TOP_LEVEL,
    "build-publish": BUILD_PUBLISH_TOP_LEVEL,
    "install": INSTALL_TOP_LEVEL,
}


def fail(message: str) -> None:
    print(f"merge-release-configs: {message}", file=sys.stderr)
    raise SystemExit(2)


def deep_merge(left: Any, right: Any, path: str) -> Any:
    if left is None:
        return right
    if right is None:
        return left
    if isinstance(left, dict) and isinstance(right, dict):
        out: dict[str, Any] = dict(left)
        for key, value in right.items():
            child = f"{path}.{key}" if path else key
            if key in out:
                out[key] = deep_merge(out[key], value, child)
            else:
                out[key] = value
        return out
    if left == right:
        return left
    fail(f"conflicting values at {path or '<root>'}")


def validate_top_level(role: str, data: Any, path: Path) -> dict[str, Any]:
    if not isinstance(data, dict):
        fail(f"{role} config {path} must be a top-level mapping")
    allowed = ROLE_ALLOWED[role]
    unknown = sorted(set(data.keys()) - allowed)
    if unknown:
        fail(
            f"{role} config {path} has unexpected top-level key(s): {', '.join(unknown)}; "
            f"allowed: {', '.join(sorted(allowed))}"
        )
    for key in allowed:
        if key not in data:
            fail(f"{role} config {path} is missing required top-level key: {key}")
    return data


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Merge devhost, build/publish, and install release configs (disjoint keys)."
    )
    parser.add_argument("--devhost-config", required=True)
    parser.add_argument("--build-publish-config", required=True)
    parser.add_argument("--install-config", required=True)
    parser.add_argument("--output", required=True, help="Write merged JSON/YAML path")
    args = parser.parse_args()

    devhost_path = Path(args.devhost_config).expanduser().resolve()
    build_path = Path(args.build_publish_config).expanduser().resolve()
    install_path = Path(args.install_config).expanduser().resolve()
    out_path = Path(args.output).expanduser().resolve()

    for label, path in (
        ("devhost", devhost_path),
        ("build-publish", build_path),
        ("install", install_path),
    ):
        if not path.is_file():
            fail(f"{label} config not found: {path}")

    devhost = validate_top_level("devhost", load_config(devhost_path), devhost_path)
    build = validate_top_level("build-publish", load_config(build_path), build_path)
    install = validate_top_level("install", load_config(install_path), install_path)

    merged: dict[str, Any] = {}
    for role, piece in (("devhost", devhost), ("build-publish", build), ("install", install)):
        for key, value in piece.items():
            if key in merged:
                fail(f"top-level key {key!r} appears in more than one config (while merging {role})")
            merged[key] = value

    out_path.parent.mkdir(parents=True, exist_ok=True)
    # JSON is supported by config_query and preserves bools/nesting without a YAML writer.
    out_path.write_text(json.dumps(merged, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(str(out_path))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
