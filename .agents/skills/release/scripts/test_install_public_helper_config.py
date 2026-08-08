#!/usr/bin/env python3
"""Tests for install.image_pull_registry + related public-helper wiring."""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
COMMON_SH = SCRIPT_DIR / "common.sh"
INSTALL_HELPER = (
    SCRIPT_DIR.parents[3] / "scripts" / "install-release.sh"
)
RUN_INSTALL = SCRIPT_DIR / "run-install-via-public-helper-on-target.sh"


def _bash(script: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    merged = os.environ.copy()
    if env:
        merged.update(env)
    return subprocess.run(
        ["bash", "-lc", script],
        check=False,
        text=True,
        capture_output=True,
        env=merged,
    )


def test_resolve_install_image_pull_registry_disabled() -> None:
    with tempfile.TemporaryDirectory(prefix="image-pull-off-") as tmp:
        cfg = Path(tmp) / "install.yaml"
        cfg.write_text("install:\n  appliance_name: x\n  dns_zone: appliance.internal\n", encoding="utf-8")
        result = _bash(
            f'source "{COMMON_SH}"; resolve_install_image_pull_registry "{cfg}"; '
            'printf "%s\\n" "${IMAGE_PULL_REGISTRY}"'
        )
        assert result.returncode == 0, result.stderr
        assert result.stdout.strip() == ""


def test_resolve_install_image_pull_registry_from_env() -> None:
    with tempfile.TemporaryDirectory(prefix="image-pull-on-") as tmp:
        cfg = Path(tmp) / "install.yaml"
        cfg.write_text(
            "\n".join(
                [
                    "install:",
                    "  appliance_name: x",
                    "  dns_zone: appliance.internal",
                    "  image_pull_registry:",
                    "    registry_env: DEV_REGISTRY",
                    "    username_env: DEV_REGISTRY_USER",
                    "    token_env: DEV_REGISTRY_TOKEN",
                    "    tls_verify_env: DEV_REGISTRY_TLS_VERIFY",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        result = _bash(
            f'source "{COMMON_SH}"; resolve_install_image_pull_registry "{cfg}"; '
            'printf "%s|%s|%s|%s|%s\\n" '
            '"${IMAGE_PULL_REGISTRY}" "${IMAGE_PULL_USERNAME_ENV}" '
            '"${IMAGE_PULL_TOKEN_ENV}" "${IMAGE_PULL_TLS_VERIFY_ENV}" '
            '"${IMAGE_PULL_PRESERVE_ENV}"',
            env={
                "DEV_REGISTRY": "192.168.1.153",
                "DEV_REGISTRY_USER": "admin",
                "DEV_REGISTRY_TOKEN": "tok",
                "DEV_REGISTRY_TLS_VERIFY": "false",
            },
        )
        assert result.returncode == 0, result.stderr
        assert (
            result.stdout.strip()
            == "192.168.1.153|DEV_REGISTRY_USER|DEV_REGISTRY_TOKEN|DEV_REGISTRY_TLS_VERIFY|"
            "DEV_REGISTRY_USER,DEV_REGISTRY_TOKEN,DEV_REGISTRY_TLS_VERIFY"
        )


def test_reject_literal_image_pull_registry() -> None:
    with tempfile.TemporaryDirectory(prefix="image-pull-literal-") as tmp:
        cfg = Path(tmp) / "install.yaml"
        cfg.write_text(
            "install:\n  image_pull_registry:\n    registry: 192.168.1.153\n",
            encoding="utf-8",
        )
        result = _bash(
            f'source "{COMMON_SH}"; reject_removed_install_image_pull_literal_registry "{cfg}"'
        )
        assert result.returncode != 0
        assert "registry_env" in result.stderr


def test_partial_image_pull_registry_fails() -> None:
    with tempfile.TemporaryDirectory(prefix="image-pull-partial-") as tmp:
        cfg = Path(tmp) / "install.yaml"
        cfg.write_text(
            "install:\n  image_pull_registry:\n    username_env: DEV_REGISTRY_USER\n",
            encoding="utf-8",
        )
        result = _bash(f'source "{COMMON_SH}"; resolve_install_image_pull_registry "{cfg}"')
        assert result.returncode != 0
        assert "registry_env is required" in result.stderr


def test_resolve_install_extra_tls_sans() -> None:
    with tempfile.TemporaryDirectory(prefix="tls-sans-") as tmp:
        cfg = Path(tmp) / "install.yaml"
        cfg.write_text(
            "install:\n  additional_tls_sans_csv: 192.168.1.101, demo.example\n",
            encoding="utf-8",
        )
        result = _bash(
            f'source "{COMMON_SH}"; resolve_install_extra_tls_sans "{cfg}"; '
            'printf "%s\\n" "${EXTRA_TLS_SANS}"'
        )
        assert result.returncode == 0, result.stderr
        assert result.stdout.strip() == "192.168.1.101 demo.example"


def test_install_release_wires_image_pull_flags() -> None:
    text = INSTALL_HELPER.read_text(encoding="utf-8")
    assert 'IMAGE_PULL_REGISTRY=""' in text
    assert "--image-pull-registry" in text
    assert "--preserve-env=" in text
    assert "image-pull-registry:" in text


def test_run_install_patches_image_pull_and_dns() -> None:
    text = RUN_INSTALL.read_text(encoding="utf-8")
    assert "resolve_install_image_pull_registry" in text
    assert "resolve_install_extra_tls_sans" in text
    assert "install.dns_zone" in text
    assert "IMAGE_PULL_REGISTRY" in text
    assert "DNS_ZONE" in text
    assert "EXTRA_TLS_SANS" in text
    assert "OUT_DIR" in text
    assert "--preserve-env=" in text
    assert "LOCAL_HELPER" in text
    assert "scp -q" in text
    # Patched into the downloaded helper on the target (escaped inside remote_cmd).
    assert 'set_assign(text, \\"IMAGE_PULL_REGISTRY\\"' in text
    assert 'set_assign(text, \\"DNS_ZONE\\"' in text
    assert 'set_assign(text, \\"EXTRA_TLS_SANS\\"' in text
    assert 'set_assign(text, \\"OUT_DIR\\"' in text


def test_helper_patch_assign_roundtrip() -> None:
    """Mirror the Python patcher used on the target for install knobs."""
    with tempfile.TemporaryDirectory(prefix="helper-patch-") as tmp:
        helper = Path(tmp) / "install-release.sh"
        helper.write_text(
            "\n".join(
                [
                    'DNS_ZONE="appliance.internal"',
                    'EXTRA_TLS_SANS=""',
                    'OUT_DIR=""',
                    'IMAGE_PULL_REGISTRY=""',
                    'IMAGE_PULL_USERNAME_ENV=""',
                    'IMAGE_PULL_TOKEN_ENV=""',
                    'IMAGE_PULL_TLS_VERIFY_ENV=""',
                    "",
                ]
            ),
            encoding="utf-8",
        )
        patched = subprocess.run(
            [
                "python3",
                "-",
                str(helper),
                "https://192.168.1.153/api/v1/files",
                "tok",
                "1",
                "0.1.0",
                "appliance",
                "lab.internal",
                "192.168.1.101",
                "/tmp/appliance-0.1.0",
                "192.168.1.153",
                "DEV_REGISTRY_USER",
                "DEV_REGISTRY_TOKEN",
                "DEV_REGISTRY_TLS_VERIFY",
            ],
            input="\n".join(
                [
                    "from pathlib import Path",
                    "import json",
                    "import re",
                    "import sys",
                    "",
                    "(",
                    "    path,",
                    "    base_url,",
                    "    bearer,",
                    "    tls_insecure,",
                    "    version,",
                    "    prefix,",
                    "    dns_zone,",
                    "    extra_tls_sans,",
                    "    out_dir,",
                    "    image_pull_registry,",
                    "    image_pull_username_env,",
                    "    image_pull_token_env,",
                    "    image_pull_tls_verify_env,",
                    ") = sys.argv[1:14]",
                    'text = Path(path).read_text(encoding="utf-8")',
                    "",
                    "def set_assign(text, name, value):",
                    "    pat = re.compile(r\"^\" + re.escape(name) + r\"=.*$\", re.M)",
                    '    repl = f"{name}={json.dumps(value)}"',
                    "    if pat.search(text):",
                    "        return pat.sub(repl, text, count=1)",
                    '    return text + ("" if text.endswith("\\n") else "\\n") + repl + "\\n"',
                    "",
                    'text = set_assign(text, "DNS_ZONE", dns_zone)',
                    'text = set_assign(text, "EXTRA_TLS_SANS", extra_tls_sans)',
                    'text = set_assign(text, "OUT_DIR", out_dir)',
                    'text = set_assign(text, "IMAGE_PULL_REGISTRY", image_pull_registry)',
                    'text = set_assign(text, "IMAGE_PULL_USERNAME_ENV", image_pull_username_env)',
                    'text = set_assign(text, "IMAGE_PULL_TOKEN_ENV", image_pull_token_env)',
                    'text = set_assign(text, "IMAGE_PULL_TLS_VERIFY_ENV", image_pull_tls_verify_env)',
                    'Path(path).write_text(text, encoding="utf-8")',
                    "",
                ]
            ),
            check=False,
            text=True,
            capture_output=True,
        )
        assert patched.returncode == 0, patched.stderr
        body = helper.read_text(encoding="utf-8")
        assert 'DNS_ZONE="lab.internal"' in body
        assert 'EXTRA_TLS_SANS="192.168.1.101"' in body
        assert 'OUT_DIR="/tmp/appliance-0.1.0"' in body
        assert 'IMAGE_PULL_REGISTRY="192.168.1.153"' in body
        assert 'IMAGE_PULL_USERNAME_ENV="DEV_REGISTRY_USER"' in body
        assert 'IMAGE_PULL_TOKEN_ENV="DEV_REGISTRY_TOKEN"' in body
        assert 'IMAGE_PULL_TLS_VERIFY_ENV="DEV_REGISTRY_TLS_VERIFY"' in body


def main() -> None:
    test_resolve_install_image_pull_registry_disabled()
    test_resolve_install_image_pull_registry_from_env()
    test_reject_literal_image_pull_registry()
    test_partial_image_pull_registry_fails()
    test_resolve_install_extra_tls_sans()
    test_install_release_wires_image_pull_flags()
    test_run_install_patches_image_pull_and_dns()
    test_helper_patch_assign_roundtrip()
    print("install public helper config tests passed")


if __name__ == "__main__":
    main()
