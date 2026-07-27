#!/usr/bin/env python3
"""Mint an appliance API bearer token for bundle_store.mode=appliance_files.

Prefer an already-exported token when the operator supplies one. Otherwise
log in to the distributor appliance and create a scoped API token with
artifacts.read + artifacts.write so large bundle uploads outlive short
session access JWTs.

Prints the raw bearer token to stdout. Progress and errors go to stderr.
"""

from __future__ import annotations

import argparse
import json
import os
import ssl
import sys
import urllib.error
import urllib.request
from typing import Any, Optional


DEFAULT_SCOPES = ("artifacts.read", "artifacts.write")
DEFAULT_LIFETIME_SECONDS = 24 * 60 * 60


def derive_api_origin(base_url: str) -> str:
    value = base_url.strip().rstrip("/")
    marker = "/api/v1/files"
    if marker in value:
        value = value[: value.index(marker)]
    return value.rstrip("/")


def build_ssl_context(*, insecure: bool, cacert: str) -> Optional[ssl.SSLContext]:
    if cacert:
        return ssl.create_default_context(cafile=cacert)
    if insecure:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return ctx
    return None


def http_json(
    method: str,
    url: str,
    *,
    body: dict[str, Any] | None = None,
    token: str = "",
    ssl_context: Optional[ssl.SSLContext],
) -> tuple[int, Any]:
    data = None
    headers = {"Accept": "application/json"}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, context=ssl_context, timeout=120) as resp:
            raw = resp.read()
            payload: Any = {}
            if raw:
                payload = json.loads(raw.decode("utf-8"))
            return int(resp.status), payload
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        detail = raw.decode("utf-8", errors="replace") if raw else str(exc)
        raise SystemExit(f"appliance-files-auth: {method} {url} failed: HTTP {exc.code}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise SystemExit(f"appliance-files-auth: {method} {url} failed: {exc}") from exc


def mint_token(
    *,
    api_origin: str,
    username: str,
    password: str,
    lifetime_seconds: int,
    scopes: list[str],
    ssl_context: Optional[ssl.SSLContext],
    token_name: str,
) -> str:
    origin = api_origin.rstrip("/")
    status, login = http_json(
        "POST",
        f"{origin}/api/v1/auth/login",
        body={"username": username, "password": password},
        ssl_context=ssl_context,
    )
    if status >= 300:
        raise SystemExit(f"appliance-files-auth: login failed with HTTP {status}")
    access = str(login.get("accessToken") or "")
    if not access:
        raise SystemExit("appliance-files-auth: login response missing accessToken")

    status, created = http_json(
        "POST",
        f"{origin}/api/v1/tokens",
        body={
            "name": token_name,
            "lifetimeSeconds": lifetime_seconds,
            "scopes": scopes,
        },
        token=access,
        ssl_context=ssl_context,
    )
    if status not in (200, 201):
        raise SystemExit(f"appliance-files-auth: create token failed with HTTP {status}")
    token = str(created.get("token") or "")
    if not token:
        raise SystemExit("appliance-files-auth: create token response missing token")
    return token


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--api-origin", required=True, help="Appliance origin, e.g. https://host")
    parser.add_argument("--username", required=True)
    parser.add_argument("--password", default="", help="Password value (prefer --password-env)")
    parser.add_argument("--password-env", default="", help="Env var holding the store appliance password")
    parser.add_argument("--lifetime-seconds", type=int, default=DEFAULT_LIFETIME_SECONDS)
    parser.add_argument(
        "--scopes",
        default=",".join(DEFAULT_SCOPES),
        help="Comma-separated API token scopes",
    )
    parser.add_argument("--token-name", default="appliance-release-files")
    parser.add_argument("--insecure", action="store_true", help="Skip TLS certificate verification")
    parser.add_argument("--cacert", default="", help="Path to PEM CA bundle")
    parser.add_argument(
        "--derive-origin-from-base-url",
        default="",
        help="If set, ignore --api-origin and derive origin from this files base URL",
    )
    args = parser.parse_args()

    password = args.password
    if args.password_env:
        password = os.environ.get(args.password_env, "") or password
    if not password:
        raise SystemExit(
            "appliance-files-auth: password required via --password or --password-env "
            "(distributor appliance admin/password for an already-installed artifact profile)"
        )

    api_origin = args.api_origin
    if args.derive_origin_from_base_url:
        api_origin = derive_api_origin(args.derive_origin_from_base_url)
    if not api_origin.startswith("http://") and not api_origin.startswith("https://"):
        raise SystemExit(f"appliance-files-auth: invalid api origin {api_origin!r}")

    scopes = [part.strip() for part in args.scopes.split(",") if part.strip()]
    if not scopes:
        raise SystemExit("appliance-files-auth: at least one scope is required")

    ssl_context = build_ssl_context(insecure=bool(args.insecure), cacert=args.cacert.strip())
    print(
        f"appliance-files-auth: minting API token at {api_origin} "
        f"for user {args.username} scopes={','.join(scopes)}",
        file=sys.stderr,
    )
    token = mint_token(
        api_origin=api_origin,
        username=args.username,
        password=password,
        lifetime_seconds=max(args.lifetime_seconds, 60),
        scopes=scopes,
        ssl_context=ssl_context,
        token_name=args.token_name,
    )
    sys.stdout.write(token)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
