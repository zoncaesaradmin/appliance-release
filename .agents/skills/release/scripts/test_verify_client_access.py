#!/usr/bin/env python3
"""Local tests for verify-client-access.sh against a fake appliance HTTP API."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import threading
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


ROOT = Path(__file__).resolve().parents[4]
SCRIPT = ROOT / ".agents" / "skills" / "release" / "scripts" / "verify-client-access.sh"


def fake_jwt(payload: dict) -> str:
    header = {"alg": "none", "typ": "JWT"}
    encode = lambda value: base64.urlsafe_b64encode(  # noqa: E731
        json.dumps(value, separators=(",", ":")).encode("utf-8")
    ).decode("ascii").rstrip("=")
    return f"{encode(header)}.{encode(payload)}."


class FakeApplianceHandler(BaseHTTPRequestHandler):
    server_version = "FakeAppliance/1.0"

    def log_message(self, _format: str, *_args: object) -> None:
        return

    def _write_json(self, status: int, payload: dict, headers: dict[str, str] | None = None) -> None:
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        artifact_enabled = bool(getattr(self.server, "artifact_enabled", False))
        if parsed.path == "/v2/":
            if not artifact_enabled:
                self._write_json(404, {"code": "not_found"})
                return
            if getattr(self.server, "artifact_v2_html", False):
                body = b"<!doctype html><html><body>ui</body></html>"
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            self._write_json(
                401,
                {"errors": [{"code": "UNAUTHORIZED"}]},
                {"WWW-Authenticate": 'Bearer realm="/api/v1/registry/token",service="zot"'},
            )
            return
        if parsed.path == "/api/v1/registry/repositories":
            if not artifact_enabled:
                self._write_json(404, {"code": "not_found"})
            elif self.headers.get("Authorization", "").startswith("Bearer "):
                self._write_json(200, {"repositories": []})
            else:
                self._write_json(401, {"code": "unauthorized"})
            return
        if parsed.path == "/api/v1/registry/token" and artifact_enabled:
            scope = (parse_qs(parsed.query).get("scope") or [""])[0]
            if getattr(self.server, "artifact_token_revoked", False):
                self._write_json(401, {"code": "unauthorized"})
            elif scope.startswith("repository:denied/"):
                if getattr(self.server, "artifact_denied_scope_returns_token", False):
                    self._write_json(
                        200,
                        {
                            "token": fake_jwt(
                                {
                                    "access": [
                                        {
                                            "type": "repository",
                                            "name": "denied/release-smoke",
                                            "actions": [],
                                        }
                                    ]
                                }
                            )
                        },
                    )
                else:
                    self._write_json(403, {"code": "denied"})
            else:
                self._write_json(200, {"token": "signed-registry-token"})
            return
        if self.path == "/api/v1/auth/session":
            self._write_json(200, {"username": "admin", "authMethod": "session"})
            return
        if self.path == "/api/v1/users":
            self._write_json(200, {"users": [{"username": "admin"}]})
            return
        if self.path == "/api/v1/work-profiles":
            self._write_json(
                404,
                {
                    "type": "https://appliance.local/problems/not-found",
                    "title": "Not found",
                    "status": 404,
                    "code": "not_found",
                },
            )
            return
        self._write_json(404, {"code": "not_found"})

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        payload = json.loads(raw.decode("utf-8") or "{}")

        if self.path == "/api/v1/auth/login":
            self._write_json(200, {"accessToken": "fake-access-token"})
            return
        if self.path == "/api/v1/tokens" and getattr(self.server, "artifact_enabled", False):
            self._write_json(201, {"id": "token-1", "token": "apt_fake.registry-token"})
            return

        if self.path == "/mcp":
            method = payload.get("method")
            if method == "initialize":
                self._write_json(
                    200,
                    {
                        "jsonrpc": "2.0",
                        "id": payload.get("id"),
                        "result": {"protocolVersion": "2025-11-25"},
                    },
                    {"Mcp-Session-Id": "fake-mcp-session"},
                )
                return
            if method == "tools/list":
                self._write_json(200, {"jsonrpc": "2.0", "id": payload.get("id"), "result": {"tools": []}})
                return
            if method == "tools/call":
                self._write_json(
                    200,
                    {
                        "jsonrpc": "2.0",
                        "id": payload.get("id"),
                        "error": {"code": -32601, "message": "Tool not found"},
                    },
                )
                return
        self._write_json(404, {"code": "not_found"})

    def do_DELETE(self) -> None:
        if self.path == "/api/v1/tokens/token-1" and getattr(self.server, "artifact_enabled", False):
            self.server.artifact_token_revoked = True
            self.send_response(204)
            self.end_headers()
            return
        self._write_json(404, {"code": "not_found"})


def test_disabled_build_direct_mcp_call_is_verified() -> None:
    with tempfile.TemporaryDirectory(prefix="verify-client-access-") as tmp_dir:
        tmp = Path(tmp_dir)
        server = ThreadingHTTPServer(("127.0.0.1", 0), FakeApplianceHandler)
        server.artifact_enabled = False
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            base_url = f"http://127.0.0.1:{server.server_port}"
            config_path = tmp / "config.json"
            run_dir = tmp / "run"
            config_path.write_text(
                json.dumps(
                    {
                        "client_verification": {
                            "base_url": base_url,
                            "username": "admin",
                            "builder": {"enabled": False, "expect_disabled": True},
                        }
                    }
                ),
                encoding="utf-8",
            )
            env = os.environ.copy()
            env["APPLIANCE_FIRST_ADMIN_PASSWORD"] = "fake-password"
            result = subprocess.run(
                [
                    "bash",
                    str(SCRIPT),
                    "--config",
                    str(config_path),
                    "--run-dir",
                    str(run_dir),
                    "--appliance-profile",
                    "core",
                    "--final-ok",
                ],
                cwd=ROOT,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
        finally:
            server.shutdown()
            server.server_close()

        if result.returncode != 0:
            raise AssertionError(result.stdout)

        metadata = json.loads((run_dir / "metadata" / "client-verify.json").read_text(encoding="utf-8"))
        direct = metadata["checks"]["disabledBuildRoutes"]["mcpDirectToolCall"]
        if direct["statusCode"] != 200:
            raise AssertionError(direct)
        if direct["expectedJSONRPCError"] != {"code": -32601, "message": "Tool not found"}:
            raise AssertionError(direct)
        body = json.loads(Path(direct["bodyLog"]).read_text(encoding="utf-8"))
        if body.get("error", {}).get("message") != "Tool not found":
            raise AssertionError(body)


def test_positive_artifact_access_is_verified() -> None:
    with tempfile.TemporaryDirectory(prefix="verify-artifact-access-") as tmp_dir:
        tmp = Path(tmp_dir)
        server = ThreadingHTTPServer(("127.0.0.1", 0), FakeApplianceHandler)
        server.artifact_enabled = True
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            run_dir = tmp / "run"
            env = os.environ.copy()
            env["APPLIANCE_ACCESS_TOKEN"] = "session-token"
            result = subprocess.run(
                [
                    "python3",
                    str(ROOT / ".agents/skills/release/scripts/verify-artifact-access.py"),
                    "--base-url",
                    f"http://127.0.0.1:{server.server_port}",
                    "--username",
                    "admin",
                    "--run-dir",
                    str(run_dir),
                    "--enabled",
                ],
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
        finally:
            server.shutdown()
            server.server_close()
        if result.returncode != 0:
            raise AssertionError(result.stdout)
        evidence = json.loads(
            (run_dir / "metadata" / "artifact-client-verify.json").read_text(encoding="utf-8")
        )
        if evidence.get("tokenIssued") is not True or evidence.get("deniedScopeStatusCode") != 403:
            raise AssertionError(evidence)


def test_artifact_access_reports_html_v2_misroute() -> None:
    with tempfile.TemporaryDirectory(prefix="verify-artifact-access-") as tmp_dir:
        tmp = Path(tmp_dir)
        server = ThreadingHTTPServer(("127.0.0.1", 0), FakeApplianceHandler)
        server.artifact_enabled = True
        server.artifact_v2_html = True
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            run_dir = tmp / "run"
            env = os.environ.copy()
            env["APPLIANCE_ACCESS_TOKEN"] = "session-token"
            result = subprocess.run(
                [
                    "python3",
                    str(ROOT / ".agents/skills/release/scripts/verify-artifact-access.py"),
                    "--base-url",
                    f"http://127.0.0.1:{server.server_port}",
                    "--username",
                    "admin",
                    "--run-dir",
                    str(run_dir),
                    "--enabled",
                ],
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
        finally:
            server.shutdown()
            server.server_close()
        if result.returncode == 0:
            raise AssertionError("expected verify-artifact-access to fail when /v2/ serves HTML")
        if "resolved to HTML instead of the OCI registry" not in result.stdout:
            raise AssertionError(result.stdout)


def test_positive_artifact_access_accepts_denied_scope_token_with_empty_actions() -> None:
    with tempfile.TemporaryDirectory(prefix="verify-artifact-access-") as tmp_dir:
        tmp = Path(tmp_dir)
        server = ThreadingHTTPServer(("127.0.0.1", 0), FakeApplianceHandler)
        server.artifact_enabled = True
        server.artifact_denied_scope_returns_token = True
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            run_dir = tmp / "run"
            env = os.environ.copy()
            env["APPLIANCE_ACCESS_TOKEN"] = "session-token"
            result = subprocess.run(
                [
                    "python3",
                    str(ROOT / ".agents/skills/release/scripts/verify-artifact-access.py"),
                    "--base-url",
                    f"http://127.0.0.1:{server.server_port}",
                    "--username",
                    "admin",
                    "--run-dir",
                    str(run_dir),
                    "--enabled",
                ],
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
        finally:
            server.shutdown()
            server.server_close()
        if result.returncode != 0:
            raise AssertionError(result.stdout)
        evidence = json.loads(
            (run_dir / "metadata" / "artifact-client-verify.json").read_text(encoding="utf-8")
        )
        if evidence.get("deniedScopeStatusCode") != 200 or evidence.get("deniedScopeGranted") is not False:
            raise AssertionError(evidence)


if __name__ == "__main__":
    test_disabled_build_direct_mcp_call_is_verified()
    test_positive_artifact_access_is_verified()
    test_artifact_access_reports_html_v2_misroute()
    test_positive_artifact_access_accepts_denied_scope_token_with_empty_actions()
    print("verify-client-access tests passed")
