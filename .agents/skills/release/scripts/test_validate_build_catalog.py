#!/usr/bin/env python3
"""Local tests for validate-build-catalog.py."""

import json
import subprocess
import tempfile
from pathlib import Path
from typing import Optional


ROOT = Path(__file__).resolve().parents[4]
VALIDATOR = ROOT / ".agents" / "skills" / "release" / "scripts" / "validate-build-catalog.py"


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def run_validator(config: Path, catalog: Path, output: Optional[Path] = None) -> subprocess.CompletedProcess:
    args = ["python3", str(VALIDATOR), "--config", str(config), "--build-catalog", str(catalog)]
    if output is not None:
        args.extend(["--output-json", str(output)])
    return subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)


def test_accepts_workspace_catalog_with_bundled_provisioner_image_ref() -> None:
    with tempfile.TemporaryDirectory(prefix="validate-build-catalog-") as tmp_dir:
        tmp = Path(tmp_dir)
        catalog = tmp / "catalog.yaml"
        image_ref = "registry.local/workspace-provisioner@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        write(
            catalog,
            f"""
workProfiles:
  - name: builder
    repos:
      - name: app
repos:
  - name: app
    url: https://git.internal.example.com/team/app.git
workspaceProvisionerImageDigest: {image_ref}
""".lstrip(),
        )
        config = tmp / "config.yaml"
        write(config, f"build_flow:\n  extra_oci_image_refs: {image_ref}\n")
        output = tmp / "validation.json"

        result = run_validator(config, catalog, output)
        if result.returncode != 0:
            raise AssertionError(result.stderr or result.stdout)
        payload = json.loads(output.read_text(encoding="utf-8"))
        if payload.get("valid") is not True or payload.get("validationErrors") != []:
            raise AssertionError(payload)


def test_rejects_placeholder_workspace_provisioner_image_ref_before_install() -> None:
    with tempfile.TemporaryDirectory(prefix="validate-build-catalog-") as tmp_dir:
        tmp = Path(tmp_dir)
        catalog = tmp / "catalog.yaml"
        image_ref = "registry.local/workspace-provisioner@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        write(
            catalog,
            f"""
workProfiles:
  - name: builder
    repos:
      - name: app
repos:
  - name: app
    url: https://git.internal.example.com/team/app.git
workspaceProvisionerImageDigest: {image_ref}
""".lstrip(),
        )
        config = tmp / "config.yaml"
        write(config, f"build_flow:\n  extra_oci_image_refs: {image_ref}\n")

        result = run_validator(config, catalog)
        if result.returncode == 0:
            raise AssertionError("placeholder workspace provisioner image ref was accepted")
        payload = json.loads(result.stdout)
        joined = "\n".join(payload["validationErrors"])
        if "sample placeholder digest" not in joined:
            raise AssertionError(payload)


def test_rejects_unbundled_workspace_provisioner_image_ref_before_install() -> None:
    with tempfile.TemporaryDirectory(prefix="validate-build-catalog-") as tmp_dir:
        tmp = Path(tmp_dir)
        catalog = tmp / "catalog.yaml"
        write(
            catalog,
            """
workProfiles:
  - name: builder
    repos:
      - name: app
repos:
  - name: app
    url: https://git.internal.example.com/team/app.git
workspaceProvisionerImageDigest: registry.local/workspace-provisioner@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
""".lstrip(),
        )
        config = tmp / "config.yaml"
        write(
            config,
            "build_flow:\n  extra_oci_image_refs: registry.local/other@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n",
        )

        result = run_validator(config, catalog)
        if result.returncode == 0:
            raise AssertionError("unbundled workspace provisioner image ref was accepted")
        payload = json.loads(result.stdout)
        joined = "\n".join(payload["validationErrors"])
        if "build_flow.extra_oci_image_refs" not in joined:
            raise AssertionError(payload)


if __name__ == "__main__":
    test_accepts_workspace_catalog_with_bundled_provisioner_image_ref()
    test_rejects_placeholder_workspace_provisioner_image_ref_before_install()
    test_rejects_unbundled_workspace_provisioner_image_ref_before_install()
