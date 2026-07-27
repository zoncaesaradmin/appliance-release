#!/usr/bin/env python3
"""Unit tests for bundle_store mode normalization (static_http|appliance_files)."""

from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[4]
MODE_LIB = REPO_ROOT / "scripts" / "publish" / "bundle-store-lib.sh"
COMMON = Path(__file__).resolve().parent / "common.sh"


def run_bash(script: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
    )


class BundleStoreModeTests(unittest.TestCase):
    def test_normalize_modes(self) -> None:
        script = f"""
set -euo pipefail
source {MODE_LIB.as_posix()!r}
normalize_bundle_store_mode ''
normalize_bundle_store_mode static_http
normalize_bundle_store_mode http
normalize_bundle_store_mode HTTP-static
normalize_bundle_store_mode appliance_files
normalize_bundle_store_mode fileserver
"""
        proc = run_bash(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(
            proc.stdout.strip().splitlines(),
            [
                "static_http",
                "static_http",
                "static_http",
                "static_http",
                "appliance_files",
                "appliance_files",
            ],
        )

    def test_normalize_rejects_oci_and_unknown(self) -> None:
        for mode in ("oci", "s3"):
            script = f"""
set -euo pipefail
source {MODE_LIB.as_posix()!r}
normalize_bundle_store_mode {mode}
"""
            proc = run_bash(script)
            self.assertNotEqual(proc.returncode, 0, mode)
            self.assertIn("must be static_http or appliance_files", proc.stderr)

    def test_resolve_mode_from_bundle_store_config_default_static_http(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / "cfg.yaml"
            cfg.write_text("bundle_store:\n  base_url: http://example\n", encoding="utf-8")
            script = f"""
set -euo pipefail
source {COMMON.as_posix()!r}
resolve_bundle_store_mode {cfg.as_posix()!r}
"""
            proc = run_bash(script)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "static_http")

    def test_resolve_mode_from_bundle_store_config_appliance_files(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / "cfg.yaml"
            cfg.write_text(
                "bundle_store:\n  mode: appliance_files\n  base_url: https://reg.example/api/v1/files\n",
                encoding="utf-8",
            )
            script = f"""
set -euo pipefail
source {COMMON.as_posix()!r}
resolve_bundle_store_mode {cfg.as_posix()!r}
"""
            proc = run_bash(script)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "appliance_files")

    def test_resolve_mode_accepts_legacy_fileserver_alias(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / "cfg.yaml"
            cfg.write_text(
                "bundle_store:\n  mode: fileserver\n  base_url: https://reg.example/api/v1/files\n",
                encoding="utf-8",
            )
            script = f"""
set -euo pipefail
source {COMMON.as_posix()!r}
resolve_bundle_store_mode {cfg.as_posix()!r}
"""
            proc = run_bash(script)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "appliance_files")

    def test_publish_release_help_mentions_appliance_files_not_oci(self) -> None:
        proc = subprocess.run(
            ["bash", str(REPO_ROOT / "scripts" / "publish" / "publish-release.sh"), "--help"],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("--mode", proc.stdout)
        self.assertIn("appliance_files", proc.stdout)
        self.assertIn("static_http", proc.stdout)
        self.assertNotIn("oci", proc.stdout.lower())
        self.assertNotIn("--oci-registry", proc.stdout)


if __name__ == "__main__":
    unittest.main()
