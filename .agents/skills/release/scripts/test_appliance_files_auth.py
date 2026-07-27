#!/usr/bin/env python3
"""Unit tests for appliance_files auth helpers and TLS/base_url guards."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import urlparse


COMMON = Path(__file__).resolve().parent / "common.sh"
AUTH_SCRIPT = Path(__file__).resolve().parent / "appliance-files-auth.py"


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


class _AuthHandler(BaseHTTPRequestHandler):
    def log_message(self, format: str, *args) -> None:  # noqa: A003
        return

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        return json.loads(raw.decode("utf-8"))

    def _write_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        payload = self._read_json()
        if path == "/api/v1/auth/login":
            if payload.get("username") == "admin" and payload.get("password") == "secret":
                self._write_json(200, {"accessToken": "session-access-token"})
                return
            self._write_json(401, {"title": "unauthorized"})
            return
        if path == "/api/v1/tokens":
            auth = self.headers.get("Authorization", "")
            if auth != "Bearer session-access-token":
                self._write_json(401, {"title": "unauthorized"})
                return
            scopes = payload.get("scopes") or []
            if "artifacts.write" not in scopes or "artifacts.read" not in scopes:
                self._write_json(400, {"title": "bad scopes"})
                return
            self._write_json(201, {"token": "apt_test_token_value", "id": "tok-1"})
            return
        self._write_json(404, {"title": "not found"})


class ApplianceFilesAuthTests(unittest.TestCase):
    def test_derive_api_origin(self) -> None:
        script = f"""
set -euo pipefail
source {COMMON.as_posix()!r}
derive_appliance_files_api_origin 'https://host.example/api/v1/files'
derive_appliance_files_api_origin 'https://host.example/api/v1/files/' 'https://override.example'
"""
        proc = run_bash(script)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(
            proc.stdout.strip().splitlines(),
            ["https://host.example", "https://override.example"],
        )

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

    def test_tls_args_default_insecure(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / "cfg.yaml"
            cfg.write_text("bundle_store:\n  mode: appliance_files\n", encoding="utf-8")
            script = f"""
set -euo pipefail
source {COMMON.as_posix()!r}
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
                f"bundle_store:\n  cacert_path: {ca.as_posix()}\n  tls_insecure: false\n",
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

    def test_mint_token_via_login(self) -> None:
        # Standalone mint helper remains available for operators; the release
        # skill itself reads bundle_store.access_token only.
        server = HTTPServer(("127.0.0.1", 0), _AuthHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            host, port = server.server_address
            origin = f"http://{host}:{port}"
            proc = subprocess.run(
                [
                    "python3",
                    str(AUTH_SCRIPT),
                    "--api-origin",
                    origin,
                    "--username",
                    "admin",
                    "--password",
                    "secret",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "apt_test_token_value")
        finally:
            server.shutdown()
            server.server_close()

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
resolve_appliance_files_bearer_token {cfg.as_posix()!r} 'https://host.example/api/v1/files'
"""
            proc = run_bash(script)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "apt_config.token")

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
resolve_appliance_files_bearer_token {cfg.as_posix()!r} 'https://host.example/api/v1/files'
"""
            proc = run_bash(script)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("access_token", proc.stderr)


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
