#!/usr/bin/env python3
"""Unit tests for bundle_store distribution modes."""

import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[4]
COMMON = Path(__file__).resolve().parent / "common.sh"


def run_bash(script: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
    )


class BundleStoreModeTests(unittest.TestCase):
    def test_normalize_supported_modes_and_empty(self) -> None:
        script = f"""
set -euo pipefail
source {COMMON.as_posix()!r}
normalize_bundle_store_mode appliance_files
normalize_bundle_store_mode static_http
normalize_bundle_store_mode ''
"""
        proc = run_bash(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(
            proc.stdout.strip().splitlines(),
            [
                "appliance_files",
                "static_http",
                "appliance_files",
            ],
        )

    def test_normalize_rejects_oci_and_unknown(self) -> None:
        for mode in ("oci", "s3"):
            script = f"""
set -euo pipefail
source {COMMON.as_posix()!r}
normalize_bundle_store_mode {mode}
"""
            proc = run_bash(script)
            self.assertNotEqual(proc.returncode, 0, mode)
            self.assertIn("must be appliance_files or static_http", proc.stderr)

    def test_resolve_mode_defaults_when_omitted(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / "cfg.yaml"
            cfg.write_text("bundle_store: {}\n", encoding="utf-8")
            script = f"""
set -euo pipefail
source {COMMON.as_posix()!r}
resolve_bundle_store_mode {cfg.as_posix()!r}
"""
            proc = run_bash(script)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "appliance_files")

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

    def test_resolve_static_http_fields(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / "cfg.yaml"
            cfg.write_text(
                "bundle_store:\n"
                "  mode: static_http\n"
                "  base_url: http://192.168.1.152:28081/\n"
                "  publish_directory: /home/zonsys/releases/\n",
                encoding="utf-8",
            )
            script = f"""
set -euo pipefail
source {COMMON.as_posix()!r}
resolve_bundle_store_mode {cfg.as_posix()!r}
resolve_static_http_base_url {cfg.as_posix()!r}
printf '\n'
resolve_static_http_publish_directory {cfg.as_posix()!r}
"""
            proc = run_bash(script)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(
                proc.stdout.strip().splitlines(),
                ["static_http", "http://192.168.1.152:28081", "/home/zonsys/releases"],
            )

    def test_static_http_rejects_root_publish_directory(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / "cfg.yaml"
            cfg.write_text(
                "bundle_store:\n  mode: static_http\n  publish_directory: /\n",
                encoding="utf-8",
            )
            script = f"""
set -euo pipefail
source {COMMON.as_posix()!r}
resolve_static_http_publish_directory {cfg.as_posix()!r}
"""
            proc = run_bash(script)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("other than /", proc.stderr)

    def test_static_http_rejects_appliance_file_credentials(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / "cfg.yaml"
            cfg.write_text(
                "bundle_store:\n"
                "  mode: static_http\n"
                "  base_url: http://192.0.2.152:28081\n"
                "  publish_directory: /home/build/releases\n"
                "  token_env: DEV_REGISTRY_TOKEN\n",
                encoding="utf-8",
            )
            script = f"""
set -euo pipefail
source {COMMON.as_posix()!r}
resolve_bundle_store_mode {cfg.as_posix()!r}
"""
            proc = run_bash(script)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("cannot include appliance_files key", proc.stderr)

    def test_publish_release_help_mentions_both_transports(self) -> None:
        proc = subprocess.run(
            ["bash", str(REPO_ROOT / "scripts" / "publish-release.sh"), "--help"],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("DEV_REGISTRY", proc.stdout)
        self.assertIn("appliance file API", proc.stdout)
        self.assertIn("static_http", proc.stdout)
        self.assertNotIn("--mode", proc.stdout)
        self.assertNotIn("oci", proc.stdout.lower())
        self.assertNotIn("--oci-registry", proc.stdout)


if __name__ == "__main__":
    unittest.main()
