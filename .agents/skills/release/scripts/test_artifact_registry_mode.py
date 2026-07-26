#!/usr/bin/env python3
"""Unit tests for artifact_registry mode normalization and OCI lib helpers."""

from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[4]
OCI_LIB = REPO_ROOT / "scripts" / "publish" / "oci-release-lib.sh"
COMMON = Path(__file__).resolve().parent / "common.sh"


def run_bash(script: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
    )


class ArtifactRegistryModeTests(unittest.TestCase):
    def test_normalize_modes(self) -> None:
        script = f"""
set -euo pipefail
source {OCI_LIB.as_posix()!r}
normalize_artifact_registry_mode ''
normalize_artifact_registry_mode http
normalize_artifact_registry_mode HTTP-static
normalize_artifact_registry_mode oci
"""
        proc = run_bash(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip().splitlines(), ["http", "http", "http", "oci"])

    def test_normalize_rejects_unknown(self) -> None:
        script = f"""
set -euo pipefail
source {OCI_LIB.as_posix()!r}
normalize_artifact_registry_mode s3
"""
        proc = run_bash(script)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("must be http or oci", proc.stderr)

    def test_resolve_mode_from_config_default_http(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / "cfg.yaml"
            cfg.write_text("artifact_registry:\n  base_url: http://example\n", encoding="utf-8")
            script = f"""
set -euo pipefail
source {COMMON.as_posix()!r}
resolve_artifact_registry_mode {cfg.as_posix()!r}
"""
            proc = run_bash(script)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "http")

    def test_resolve_mode_from_config_oci(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / "cfg.yaml"
            cfg.write_text(
                "artifact_registry:\n  mode: oci\n  oci_registry: reg.example\n",
                encoding="utf-8",
            )
            script = f"""
set -euo pipefail
source {COMMON.as_posix()!r}
resolve_artifact_registry_mode {cfg.as_posix()!r}
"""
            proc = run_bash(script)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "oci")

    def test_publish_release_help_mentions_oci(self) -> None:
        proc = subprocess.run(
            ["bash", str(REPO_ROOT / "scripts" / "publish" / "publish-release.sh"), "--help"],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("--mode", proc.stdout)
        self.assertIn("oci", proc.stdout)
        self.assertIn("--oci-registry", proc.stdout)

    def test_install_oci_help(self) -> None:
        proc = subprocess.run(
            ["bash", str(REPO_ROOT / "scripts" / "publish" / "install-oci-release.sh"), "--help"],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("--oci-registry", proc.stdout)
        self.assertIn("--oci-repository", proc.stdout)


if __name__ == "__main__":
    unittest.main()
