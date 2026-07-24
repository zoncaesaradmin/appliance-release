#!/usr/bin/env python3
"""Verify profile-aware OCI registry access without persisting credentials."""

from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request


def request(url: str, *, method: str = "GET", token: str = "", basic: tuple[str, str] | None = None, body=None):
    headers = {}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if basic:
        import base64

        raw = base64.b64encode(f"{basic[0]}:{basic[1]}".encode()).decode()
        headers["Authorization"] = f"Basic {raw}"
    data = None
    if body is not None:
        data = json.dumps(body, separators=(",", ":")).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, context=ssl._create_unverified_context()) as response:
            return response.status, dict(response.headers), response.read()
    except urllib.error.HTTPError as exc:
        return exc.code, dict(exc.headers), exc.read()


def looks_like_html(body: bytes, headers: dict[str, str]) -> bool:
    content_type = headers.get("Content-Type") or headers.get("content-type") or ""
    if "html" in content_type.lower():
        return True
    snippet = body[:200].lstrip().lower()
    return snippet.startswith(b"<!doctype html") or snippet.startswith(b"<html")


def decode_jwt_claims(token: str) -> dict:
    parts = token.split(".")
    if len(parts) != 3:
        raise ValueError("registry token is not a JWT")
    payload = parts[1]
    padding = "=" * (-len(payload) % 4)
    decoded = base64.urlsafe_b64decode(payload + padding)
    return json.loads(decoded.decode("utf-8"))


def token_grants_action(claims: dict, repository: str, action: str) -> bool:
    for entry in claims.get("access") or []:
        if entry.get("type") != "repository":
            continue
        if entry.get("name") != repository:
            continue
        actions = entry.get("actions") or []
        if action in actions:
            return True
    return False


def run_smoke(label: str, command: str, env: dict[str, str], logs: Path) -> dict:
    if not command:
        return {"configured": False}
    result = subprocess.run(
        command,
        shell=True,
        executable="/bin/bash",
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    log_path = logs / f"client-artifact-{label}.log"
    redacted = result.stdout
    registry_token = env.get("APPLIANCE_REGISTRY_TOKEN", "")
    if registry_token:
        redacted = redacted.replace(registry_token, "<redacted>")
    log_path.write_text(redacted, encoding="utf-8")
    if result.returncode:
        raise ValueError(f"{label} smoke failed with exit {result.returncode}; log: {log_path}")
    return {"configured": True, "exitCode": 0, "log": str(log_path)}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--username", required=True)
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--enabled", action="store_true")
    parser.add_argument("--oci-smoke-command", default="")
    parser.add_argument("--oras-smoke-command", default="")
    parser.add_argument("--offline-smoke-command", default="")
    args = parser.parse_args()
    access_token = os.environ.get("APPLIANCE_ACCESS_TOKEN", "")
    if not access_token:
        raise ValueError("APPLIANCE_ACCESS_TOKEN is required")
    base = args.base_url.rstrip("/")
    logs = Path(args.run_dir) / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    evidence: dict = {"enabled": args.enabled}
    output = Path(args.run_dir) / "metadata" / "artifact-client-verify.json"
    output.parent.mkdir(parents=True, exist_ok=True)

    catalog_status, _, catalog_body = request(
        f"{base}/api/v1/registry/repositories", token=access_token
    )
    anonymous_catalog_status, _, _ = request(f"{base}/api/v1/registry/repositories")
    challenge_status, challenge_headers, challenge_body = request(f"{base}/v2/")
    malformed_status, malformed_headers, malformed_body = request(f"{base}/v2/", token="malformed")
    evidence.update(
        {
            "catalogStatusCode": catalog_status,
            "catalogFiltered": catalog_status < 400,
            "anonymousCatalogStatusCode": anonymous_catalog_status,
            "v2ChallengeStatusCode": challenge_status,
            "v2Challenge": challenge_headers.get("Www-Authenticate")
            or challenge_headers.get("WWW-Authenticate"),
            "malformedTokenStatusCode": malformed_status,
        }
    )
    if not args.enabled:
        if catalog_status != 404:
            raise ValueError(f"disabled artifact route returned HTTP {catalog_status}; want 404")
        if challenge_status not in (404, 503):
            raise ValueError(f"disabled /v2/ returned HTTP {challenge_status}; want 404 or 503")
        output.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(json.dumps(evidence, sort_keys=True))
        return 0

    if catalog_status >= 400:
        raise ValueError(f"registry catalog returned HTTP {catalog_status}: {catalog_body[:200]!r}")
    if anonymous_catalog_status not in (401, 403):
        raise ValueError(f"anonymous registry catalog returned HTTP {anonymous_catalog_status}; want 401/403")
    if challenge_status != 401 or not evidence["v2Challenge"]:
        if looks_like_html(challenge_body, challenge_headers):
            raise ValueError("registry /v2/ resolved to HTML instead of the OCI registry; check the public /v2 route or host matching")
        raise ValueError(
            f"registry /v2/ did not return a bearer authentication challenge "
            f"(status {challenge_status}, WWW-Authenticate={evidence['v2Challenge']!r})"
        )
    if malformed_status not in (401, 403):
        if looks_like_html(malformed_body, malformed_headers):
            raise ValueError("registry /v2/ with a malformed token resolved to HTML instead of the OCI registry; check the public /v2 route or host matching")
        raise ValueError(f"malformed registry token returned HTTP {malformed_status}; want 401/403")

    create_status, _, create_body = request(
        f"{base}/api/v1/tokens",
        method="POST",
        token=access_token,
        body={"name": "release-artifact-smoke", "lifetimeSeconds": 3600},
    )
    if create_status != 201:
        raise ValueError(f"API-token creation returned HTTP {create_status}")
    created = json.loads(create_body)
    api_token = str(created.get("token") or "")
    token_id = str(created.get("id") or "")
    if not api_token or not token_id:
        raise ValueError("API-token creation omitted token or id")
    try:
        query = urllib.parse.urlencode(
            {"service": "zot", "scope": "repository:release-smoke:pull,push"}
        )
        token_status, _, token_body = request(
            f"{base}/api/v1/registry/token?{query}", basic=(args.username, api_token)
        )
        if token_status >= 400:
            raise ValueError(f"registry token issuance returned HTTP {token_status}")
        registry_token = json.loads(token_body)
        evidence["tokenIssuanceStatusCode"] = token_status
        evidence["tokenIssued"] = bool(registry_token.get("token") or registry_token.get("access_token"))
        if not evidence["tokenIssued"]:
            raise ValueError("registry token response omitted token")

        denied_query = urllib.parse.urlencode(
            {"service": "zot", "scope": "repository:denied/release-smoke:pull,push"}
        )
        denied_status, _, denied_body = request(
            f"{base}/api/v1/registry/token?{denied_query}", basic=(args.username, api_token)
        )
        evidence["deniedScopeStatusCode"] = denied_status
        if denied_status in (401, 403):
            evidence["deniedScopeGranted"] = False
        elif denied_status == 200:
            denied_token = json.loads(denied_body)
            denied_token_value = str(denied_token.get("token") or denied_token.get("access_token") or "")
            if not denied_token_value:
                raise ValueError("denied registry scope response omitted token")
            denied_claims = decode_jwt_claims(denied_token_value)
            evidence["deniedScopeGranted"] = token_grants_action(
                denied_claims, "denied/release-smoke", "pull"
            ) or token_grants_action(denied_claims, "denied/release-smoke", "push")
            if evidence["deniedScopeGranted"]:
                raise ValueError("denied registry scope token granted pull/push actions")
        else:
            raise ValueError(
                f"denied registry scope returned HTTP {denied_status}; want 200 with no granted actions or 401/403"
            )

        smoke_env = os.environ.copy()
        smoke_env.update(
            {
                "APPLIANCE_REGISTRY_URL": base,
                "APPLIANCE_REGISTRY_USERNAME": args.username,
                "APPLIANCE_REGISTRY_TOKEN": api_token,
            }
        )
        evidence["ociSmoke"] = run_smoke("oci-smoke", args.oci_smoke_command, smoke_env, logs)
        evidence["orasSmoke"] = run_smoke("oras-smoke", args.oras_smoke_command, smoke_env, logs)
        evidence["offlineSmoke"] = run_smoke(
            "offline-smoke", args.offline_smoke_command, smoke_env, logs
        )
    finally:
        revoke_status, _, _ = request(
            f"{base}/api/v1/tokens/{urllib.parse.quote(token_id)}",
            method="DELETE",
            token=access_token,
        )
        evidence["tokenRevokeStatusCode"] = revoke_status
        revoked_status, _, _ = request(
            f"{base}/api/v1/registry/token?{query}", basic=(args.username, api_token)
        )
        evidence["revokedCredentialStatusCode"] = revoked_status
        evidence["revokedTokenChecked"] = revoke_status < 300 and revoked_status in (401, 403)
        if not evidence["revokedTokenChecked"]:
            raise ValueError(
                "revoked API token remained usable "
                f"(revoke HTTP {revoke_status}, registry token HTTP {revoked_status})"
            )

    output.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(evidence, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"verify-artifact-access: {exc}", file=sys.stderr)
        raise SystemExit(1)
