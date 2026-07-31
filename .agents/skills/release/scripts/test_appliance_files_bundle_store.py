#!/usr/bin/env python3
"""Unit tests for appliance_files bundle-store helpers and TLS/base_url guards."""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


COMMON = Path(__file__).resolve().parent / "common.sh"


def run_bash(script: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    merged = os.environ.copy()
    if env:
        merged.update(env)
    return subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
        env=merged,
    )


class ApplianceFilesBundleStoreTests(unittest.TestCase):
    def test_require_base_url_rejects_files_prefix(self) -> None:
        script = f"""
set -euo pipefail
source {COMMON.as_posix()!r}
require_appliance_files_base_url 'https://host.example/files'
"""
        proc = run_bash(script)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("/api/v1/files", proc.stderr)

    def test_require_base_url_accepts_api_files(self) -> None:
        script = f"""
set -euo pipefail
source {COMMON.as_posix()!r}
require_appliance_files_base_url 'https://host.example/api/v1/files'
"""
        proc = run_bash(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_resolve_base_url_from_dev_registry(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / "cfg.yaml"
            cfg.write_text("bundle_store:\n  mode: appliance_files\n", encoding="utf-8")
            script = f"""
set -euo pipefail
source {COMMON.as_posix()!r}
export DEV_REGISTRY='artifact-dns-1.appliance.internal'
resolve_appliance_files_base_url {cfg.as_posix()!r}
"""
            proc = run_bash(script)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(
                proc.stdout.strip(),
                "https://artifact-dns-1.appliance.internal/api/v1/files",
            )

    def test_resolve_base_url_strips_scheme_from_registry(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / "cfg.yaml"
            cfg.write_text("bundle_store:\n  mode: appliance_files\n", encoding="utf-8")
            script = f"""
set -euo pipefail
source {COMMON.as_posix()!r}
export DEV_REGISTRY='https://artifact.example/'
resolve_appliance_files_base_url {cfg.as_posix()!r}
"""
            proc = run_bash(script)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "https://artifact.example/api/v1/files")

    def test_resolve_base_url_custom_files_path(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / "cfg.yaml"
            cfg.write_text(
                "bundle_store:\n  mode: appliance_files\n  files_path: /custom/files\n",
                encoding="utf-8",
            )
            script = f"""
set -euo pipefail
source {COMMON.as_posix()!r}
export DEV_REGISTRY='host.example'
resolve_appliance_files_base_url {cfg.as_posix()!r}
"""
            proc = run_bash(script)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "https://host.example/custom/files")

    def test_resolve_base_url_legacy_override(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / "cfg.yaml"
            cfg.write_text(
                "bundle_store:\n  mode: appliance_files\n  base_url: https://legacy.example/api/v1/files\n",
                encoding="utf-8",
            )
            script = f"""
set -euo pipefail
source {COMMON.as_posix()!r}
unset DEV_REGISTRY || true
resolve_appliance_files_base_url {cfg.as_posix()!r}
"""
            proc = run_bash(script)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "https://legacy.example/api/v1/files")

    def test_tls_args_require_env_or_insecure(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / "cfg.yaml"
            cfg.write_text("bundle_store:\n  mode: appliance_files\n", encoding="utf-8")
            script = f"""
set -euo pipefail
source {COMMON.as_posix()!r}
unset DEV_REGISTRY_TLS_VERIFY || true
bundle_store_fill_curl_tls_args {cfg.as_posix()!r}
"""
            proc = run_bash(script)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("DEV_REGISTRY_TLS_VERIFY", proc.stderr)

    def test_tls_args_from_verify_env_false(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / "cfg.yaml"
            cfg.write_text("bundle_store:\n  mode: appliance_files\n", encoding="utf-8")
            script = f"""
set -euo pipefail
source {COMMON.as_posix()!r}
export DEV_REGISTRY_TLS_VERIFY=false
bundle_store_fill_curl_tls_args {cfg.as_posix()!r}
printf '%s\\n' "${{BUNDLE_STORE_CURL_TLS_ARGS[*]}}"
"""
            proc = run_bash(script)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "-k")

    def test_tls_args_from_verify_env_true(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / "cfg.yaml"
            cfg.write_text("bundle_store:\n  mode: appliance_files\n", encoding="utf-8")
            script = f"""
set -euo pipefail
source {COMMON.as_posix()!r}
export DEV_REGISTRY_TLS_VERIFY=true
bundle_store_fill_curl_tls_args {cfg.as_posix()!r}
printf '%s\\n' "${{BUNDLE_STORE_CURL_TLS_ARGS[*]:-}}"
"""
            proc = run_bash(script)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "")

    def test_tls_args_insecure_override(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / "cfg.yaml"
            cfg.write_text(
                "bundle_store:\n  mode: appliance_files\n  tls_insecure: true\n",
                encoding="utf-8",
            )
            script = f"""
set -euo pipefail
source {COMMON.as_posix()!r}
unset DEV_REGISTRY_TLS_VERIFY || true
bundle_store_fill_curl_tls_args {cfg.as_posix()!r}
printf '%s\\n' "${{BUNDLE_STORE_CURL_TLS_ARGS[*]}}"
"""
            proc = run_bash(script)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "-k")

    def test_tls_args_respect_cacert(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / "cfg.yaml"
            ca = Path(tmp) / "ca.pem"
            ca.write_text("dummy-ca\n", encoding="utf-8")
            cfg.write_text(
                f"bundle_store:\n  cacert_path: {ca.as_posix()}\n",
                encoding="utf-8",
            )
            script = f"""
set -euo pipefail
source {COMMON.as_posix()!r}
bundle_store_fill_curl_tls_args {cfg.as_posix()!r}
printf '%s\\n' "${{BUNDLE_STORE_CURL_TLS_ARGS[0]}}"
printf '%s\\n' "${{BUNDLE_STORE_CURL_TLS_ARGS[1]}}"
"""
            proc = run_bash(script)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            lines = proc.stdout.strip().splitlines()
            self.assertEqual(lines[0], "--cacert")
            self.assertEqual(lines[1], ca.as_posix())

    def test_resolve_bearer_uses_config_access_token(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / "cfg.yaml"
            cfg.write_text(
                "\n".join(
                    [
                        "bundle_store:",
                        "  mode: appliance_files",
                        "  base_url: https://host.example/api/v1/files",
                        "  access_token: apt_config.token",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            script = f"""
set -euo pipefail
source {COMMON.as_posix()!r}
unset DEV_REGISTRY_TOKEN || true
resolve_appliance_files_bearer_token {cfg.as_posix()!r} 'https://host.example/api/v1/files'
"""
            proc = run_bash(script)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "apt_config.token")

    def test_resolve_bearer_falls_back_to_dev_registry_token(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / "cfg.yaml"
            cfg.write_text(
                "bundle_store:\n  mode: appliance_files\n  base_url: https://host.example/api/v1/files\n",
                encoding="utf-8",
            )
            script = f"""
set -euo pipefail
source {COMMON.as_posix()!r}
export DEV_REGISTRY_TOKEN='apt_env.token'
resolve_appliance_files_bearer_token {cfg.as_posix()!r} 'https://host.example/api/v1/files'
"""
            proc = run_bash(script)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "apt_env.token")

    def test_resolve_bearer_requires_access_token(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / "cfg.yaml"
            cfg.write_text(
                "bundle_store:\n  mode: appliance_files\n  base_url: https://host.example/api/v1/files\n",
                encoding="utf-8",
            )
            script = f"""
set -euo pipefail
source {COMMON.as_posix()!r}
unset DEV_REGISTRY_TOKEN || true
resolve_appliance_files_bearer_token {cfg.as_posix()!r} 'https://host.example/api/v1/files'
"""
            proc = run_bash(script)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("DEV_REGISTRY_TOKEN", proc.stderr)


class TestRemoteCurlArrayInit(unittest.TestCase):
    def test_keeps_minus_k_inside_array_parens(self) -> None:
        # Regression: appending -k outside curl_args=(...) made bash run -k as a
        # command ("-k: command not found") and left curl without insecure TLS.
        script = f"""
set -euo pipefail
source {COMMON.as_posix()!r}
BUNDLE_STORE_CURL_TLS_ARGS=(-k)
init="$(bundle_store_remote_curl_array_init curl_args -fsSIL)"
printf '%s\\n' "$init"
# Must be a single array assignment; evaluating it must not treat -k as a command.
eval "$init"
printf 'len=%s\\n' "${{#curl_args[@]}}"
printf 'joined=%s\\n' "${{curl_args[*]}}"
"""
        proc = run_bash(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("curl_args=(", proc.stdout)
        self.assertRegex(proc.stdout, r"curl_args=\(.*-k.*\)")
        self.assertIn("joined=-fsSIL -k", proc.stdout)
        # Guard the exact failure mode from the bug: no trailing ' -k' after ')'.
        init_line = next(line for line in proc.stdout.splitlines() if line.startswith("curl_args="))
        self.assertTrue(init_line.endswith(")"), init_line)
        self.assertNotRegex(init_line, r"\)\s+-k")

    def test_rewrites_mac_cacert_to_insecure(self) -> None:
        script = f"""
set -euo pipefail
source {COMMON.as_posix()!r}
BUNDLE_STORE_CURL_TLS_ARGS=(--cacert /tmp/mac-only-ca.pem)
init="$(bundle_store_remote_curl_array_init curl_tls_args)"
printf '%s\\n' "$init"
"""
        proc = run_bash(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), "curl_tls_args=( -k)")


if __name__ == "__main__":
    unittest.main()
