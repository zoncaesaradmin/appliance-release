#!/usr/bin/env python3
"""Exercise static HTTP publication and guard the normal API transport."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
PUBLISH = ROOT / "scripts" / "publish-release.sh"
PACK_NAME = "appliance-0.1.0-foundation.tar.gz"


def prepare_export(root: Path) -> Path:
    work = root / "work"
    export = work / "export"
    export.mkdir(parents=True)
    (export / PACK_NAME).write_bytes(b"signed-pack-placeholder\n")
    (export / "release-signing.pub").write_text("public-key-placeholder\n", encoding="utf-8")
    (export / "release-index.yaml").write_text(
        "version: 0.1.0\n"
        "packs:\n"
        "  - id: foundation\n"
        f"    filename: {PACK_NAME}\n",
        encoding="utf-8",
    )
    return work


def run_static_http_test() -> None:
    with tempfile.TemporaryDirectory(prefix="static-http-publish-") as temp:
        root = Path(temp)
        work = prepare_export(root)
        document_root = root / "served"

        env = os.environ.copy()
        env.update(
            {
                "PRODUCT_VERSION": "0.1.0",
                "RELEASE_WORK_ROOT": str(work),
                "PUBLISH_MODE": "static_http",
                "PUBLISH_PUBLIC_BASE_URL": "http://192.0.2.152:28081",
                "PUBLISH_STATIC_ROOT": str(document_root),
            }
        )
        env.pop("DEV_REGISTRY", None)
        env.pop("DEV_REGISTRY_TOKEN", None)
        result = subprocess.run(
            ["bash", str(PUBLISH)],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        if result.returncode != 0:
            raise AssertionError(result.stdout)

        published = document_root / "appliance" / "0.1.0"
        expected = {
            PACK_NAME,
            "release-index.yaml",
            "release-signing.pub",
            "sha256sum.txt",
            "install-release.sh",
        }
        actual = {path.name for path in published.iterdir()}
        if actual != expected:
            raise AssertionError(f"unexpected static publish contents: {actual}")

        helper = (published / "install-release.sh").read_text(encoding="utf-8")
        required_stamps = (
            'PRODUCT_VERSION_EMBEDDED="0.1.0"',
            'PATH_PREFIX_EMBEDDED="appliance"',
            'BASE_URL_EMBEDDED="http://192.0.2.152:28081"',
        )
        for stamp in required_stamps:
            if stamp not in helper:
                raise AssertionError(f"missing helper stamp: {stamp}")

        if "static HTTP document root" not in result.stdout:
            raise AssertionError(result.stdout)


def run_appliance_files_regression_test() -> None:
    with tempfile.TemporaryDirectory(prefix="appliance-files-publish-") as temp:
        root = Path(temp)
        work = prepare_export(root)
        fake_bin = root / "bin"
        fake_bin.mkdir()
        curl_log = root / "curl.log"
        fake_curl = fake_bin / "curl"
        fake_curl.write_text(
            "#!/bin/sh\n"
            "body=''\n"
            "last=''\n"
            "while [ \"$#\" -gt 0 ]; do\n"
            "  case \"$1\" in\n"
            "    -o) body=$2; shift 2 ;;\n"
            "    -w|-X|-H|-T|--cacert) shift 2 ;;\n"
            "    *) last=$1; shift ;;\n"
            "  esac\n"
            "done\n"
            "[ -z \"$body\" ] || printf '{}' >\"$body\"\n"
            "printf '%s\\n' \"$last\" >>\"$FAKE_CURL_LOG\"\n"
            "printf '201'\n",
            encoding="utf-8",
        )
        fake_curl.chmod(0o755)

        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{fake_bin}{os.pathsep}{env['PATH']}",
                "FAKE_CURL_LOG": str(curl_log),
                "PRODUCT_VERSION": "0.1.0",
                "RELEASE_WORK_ROOT": str(work),
                "PUBLISH_MODE": "appliance_files",
                "DEV_REGISTRY": "artifacts.example",
                "DEV_REGISTRY_TOKEN": "test-token",
                "DEV_REGISTRY_TLS_VERIFY": "true",
            }
        )
        result = subprocess.run(
            ["bash", str(PUBLISH)],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        if result.returncode != 0:
            raise AssertionError(result.stdout)
        urls = curl_log.read_text(encoding="utf-8").splitlines()
        if len(urls) != 5:
            raise AssertionError(f"expected five API uploads, got {urls}")
        expected_prefix = "https://artifacts.example/api/v1/files/appliance/0.1.0/"
        if any(not url.startswith(expected_prefix) for url in urls):
            raise AssertionError(f"unexpected API destinations: {urls}")
        if "published release files via appliance file API" not in result.stdout:
            raise AssertionError(result.stdout)


def main() -> None:
    run_static_http_test()
    run_appliance_files_regression_test()
    print("publish transport tests passed")


if __name__ == "__main__":
    main()
