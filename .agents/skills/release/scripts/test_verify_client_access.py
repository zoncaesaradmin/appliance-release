#!/usr/bin/env python3
"""Local tests for verify-client-access.sh against a fake appliance HTTP API."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


ROOT = Path(__file__).resolve().parents[4]
SCRIPT = ROOT / ".agents" / "skills" / "release" / "scripts" / "verify-client-access.sh"


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


def test_disabled_build_direct_mcp_call_is_verified() -> None:
    with tempfile.TemporaryDirectory(prefix="verify-client-access-") as tmp_dir:
        tmp = Path(tmp_dir)
        server = ThreadingHTTPServer(("127.0.0.1", 0), FakeApplianceHandler)
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


if __name__ == "__main__":
    test_disabled_build_direct_mcp_call_is_verified()
    print("verify-client-access tests passed")
