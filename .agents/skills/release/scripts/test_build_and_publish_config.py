#!/usr/bin/env python3
"""Local tests for build-and-publish.sh config fail-closed behavior."""

import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[4]
SCRIPT = ROOT / ".agents" / "skills" / "release" / "scripts" / "build-and-publish.sh"


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def test_rejects_literal_dev_image_repo_and_name() -> None:
    with tempfile.TemporaryDirectory(prefix="build-and-publish-config-") as tmp_dir:
        tmp = Path(tmp_dir)
        config = tmp / "config.yaml"
        run_dir = tmp / "run"
        write(
            config,
            """
build_host:
  alias: build@example
release_workspace:
  remote_repo_path: /tmp/appliance-release
  remote_export_dir: /tmp/export
  remote_repo_ref: main
release:
  version: 0.1.0
build_flow:
  bootstrap_needs_sudo: false
  build_needs_sudo: false
  build_command: bash scripts/ci/build-full-bundle.sh
  publish_command: make publish-release
  code_repo_ref: main
  ctl_repo_ref: main
  k3s_binary_source: /tmp/k3s
  k3s_airgap_images_source: /tmp/k3s-airgap-images.tar.zst
  dev_image_pull:
    registry_env: DEV_REGISTRY
    image_repo: example
    image_name: dev-build
    image_tag: latest
    username_env: DEV_REGISTRY_USER
    token_env: DEV_REGISTRY_TOKEN
    tls_verify_env: DEV_REGISTRY_TLS_VERIFY
""".lstrip(),
        )
        result = subprocess.run(
            [
                "bash",
                str(SCRIPT),
                "--config",
                str(config),
                "--run-dir",
                str(run_dir),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        if result.returncode == 0:
            raise AssertionError("literal dev_image_pull.image_repo/image_name was accepted")
        if "image_repo and image_name were removed" not in result.stdout:
            raise AssertionError(result.stdout)


def test_rejects_removed_remote_release_input_and_bundle_overrides() -> None:
    with tempfile.TemporaryDirectory(prefix="build-and-publish-config-") as tmp_dir:
        tmp = Path(tmp_dir)
        config = tmp / "config.yaml"
        run_dir = tmp / "run"
        write(
            config,
            """
build_host:
  alias: build@example
release_workspace:
  remote_repo_path: /tmp/appliance-release
  remote_export_dir: /tmp/export
  remote_repo_ref: main
  remote_release_input_path: /tmp/release-input.tar.gz
release:
  version: 0.1.0
build_flow:
  bootstrap_needs_sudo: false
  build_needs_sudo: false
  build_command: bash scripts/ci/build-full-bundle.sh
  publish_command: make publish-release
  code_repo_ref: main
  ctl_repo_ref: main
  k3s_binary_source: /tmp/k3s
  k3s_airgap_images_source: /tmp/k3s-airgap-images.tar.zst
  dev_image_pull:
    registry_env: DEV_REGISTRY
    image_repo_env: DEV_IMAGE_REPO
    image_name_env: DEV_IMAGE_NAME
    image_tag: latest
    username_env: DEV_REGISTRY_USER
    token_env: DEV_REGISTRY_TOKEN
    tls_verify_env: DEV_REGISTRY_TLS_VERIFY
""".lstrip(),
        )
        result = subprocess.run(
            [
                "bash",
                str(SCRIPT),
                "--config",
                str(config),
                "--run-dir",
                str(run_dir),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        if result.returncode == 0:
            raise AssertionError("removed remote release-input override was accepted")
        if "remote_release_input_path and remote_bundle_dir were removed" not in result.stdout:
            raise AssertionError(result.stdout)


def test_rejects_offline_archive_path_inputs() -> None:
    with tempfile.TemporaryDirectory(prefix="build-and-publish-config-") as tmp_dir:
        tmp = Path(tmp_dir)
        config = tmp / "config.yaml"
        run_dir = tmp / "run"
        write(
            config,
            """
build_host:
  alias: build@example
release_workspace:
  remote_repo_path: /tmp/appliance-release
  remote_export_dir: /tmp/export
  remote_repo_ref: main
release:
  version: 0.1.0
build_flow:
  bootstrap_needs_sudo: false
  build_needs_sudo: false
  build_command: bash scripts/ci/build-full-bundle.sh
  publish_command: make publish-release
  code_repo_ref: main
  ctl_repo_ref: main
  k3s_binary_source: /tmp/k3s
  k3s_airgap_images_source: /tmp/k3s-airgap-images.tar.zst
  zot:
    image_archive_source: /tmp/zot.oci.tar
  dev_image_pull:
    registry_env: DEV_REGISTRY
    image_repo_env: DEV_IMAGE_REPO
    image_name_env: DEV_IMAGE_NAME
    image_tag: latest
    username_env: DEV_REGISTRY_USER
    token_env: DEV_REGISTRY_TOKEN
    tls_verify_env: DEV_REGISTRY_TLS_VERIFY
""".lstrip(),
        )
        result = subprocess.run(
            [
                "bash",
                str(SCRIPT),
                "--config",
                str(config),
                "--run-dir",
                str(run_dir),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        if result.returncode == 0:
            raise AssertionError("offline image_archive_source was accepted")
        if "offline/local archive path inputs under build_flow were removed" not in result.stdout:
            raise AssertionError(result.stdout)


def main() -> None:
    test_rejects_literal_dev_image_repo_and_name()
    test_rejects_removed_remote_release_input_and_bundle_overrides()
    test_rejects_offline_archive_path_inputs()
    print("build-and-publish config tests passed")


if __name__ == "__main__":
    main()
