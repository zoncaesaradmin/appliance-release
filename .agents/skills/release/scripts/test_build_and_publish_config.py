#!/usr/bin/env python3
"""Local tests for build-and-publish.sh config fail-closed behavior."""

import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[4]
SCRIPT = ROOT / ".agents" / "skills" / "release" / "scripts" / "build-and-publish.sh"

MINIMAL_VALID_CONFIG = """
release_workspace:
  remote_build_root: /tmp/appliance-build
  remote_repo_ref: main
release:
  publish_latest_alias: false
build_flow:
  mode: online
  online_image_pull:
    registry_env: ONLINE_REGISTRY
    image_repo_env: ONLINE_IMAGE_REPO
    image_name_env: ONLINE_IMAGE_NAME
    image_tag_env: ONLINE_IMAGE_TAG
    username_env: ONLINE_REGISTRY_USER
    token_env: ONLINE_REGISTRY_TOKEN
    tls_verify_env: ONLINE_REGISTRY_TLS_VERIFY
bundle_store:
  registry_env: DEV_REGISTRY
  username_env: DEV_REGISTRY_USER
  token_env: DEV_REGISTRY_TOKEN
  tls_verify_env: DEV_REGISTRY_TLS_VERIFY
""".lstrip()


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def run_build_publish_config(config: Path, run_dir: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "bash",
            str(SCRIPT),
            "--local",
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


def test_requires_local() -> None:
    with tempfile.TemporaryDirectory(prefix="build-and-publish-config-") as tmp_dir:
        tmp = Path(tmp_dir)
        config = tmp / "config.yaml"
        run_dir = tmp / "run"
        write(config, MINIMAL_VALID_CONFIG)
        result = subprocess.run(
            ["bash", str(SCRIPT), "--config", str(config), "--run-dir", str(run_dir)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        if result.returncode == 0:
            raise AssertionError("--local should be required")
        if "requires --local" not in result.stdout:
            raise AssertionError(result.stdout)


def test_rejects_legacy_dev_image_pull() -> None:
    with tempfile.TemporaryDirectory(prefix="build-and-publish-config-") as tmp_dir:
        tmp = Path(tmp_dir)
        config = tmp / "config.yaml"
        run_dir = tmp / "run"
        write(
            config,
            """
release_workspace:
  remote_build_root: /tmp/appliance-build
  remote_repo_ref: main
release:
  publish_latest_alias: false
build_flow:
  mode: online
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
        result = run_build_publish_config(config, run_dir)
        if result.returncode == 0:
            raise AssertionError("legacy build_flow.dev_image_pull was accepted")
        if "dev_image_pull.* was removed" not in result.stdout and "dev_image_pull" not in result.stdout:
            raise AssertionError(result.stdout)


def test_rejects_missing_mode() -> None:
    with tempfile.TemporaryDirectory(prefix="build-and-publish-config-") as tmp_dir:
        tmp = Path(tmp_dir)
        config = tmp / "config.yaml"
        run_dir = tmp / "run"
        write(
            config,
            MINIMAL_VALID_CONFIG.replace("  mode: online\n", ""),
        )
        result = run_build_publish_config(config, run_dir)
        if result.returncode == 0:
            raise AssertionError("missing build_flow.mode was accepted")
        if "build_flow.mode is required" not in result.stdout:
            raise AssertionError(result.stdout)


def test_rejects_removed_remote_release_input_and_bundle_overrides() -> None:
    with tempfile.TemporaryDirectory(prefix="build-and-publish-config-") as tmp_dir:
        tmp = Path(tmp_dir)
        config = tmp / "config.yaml"
        run_dir = tmp / "run"
        write(
            config,
            MINIMAL_VALID_CONFIG.replace(
                "  remote_repo_ref: main",
                "  remote_repo_ref: main\n  remote_release_input_path: /tmp/release-input.tar.gz",
            ),
        )
        result = run_build_publish_config(config, run_dir)
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
            MINIMAL_VALID_CONFIG.replace(
                "build_flow:",
                "build_flow:\n  zot:\n    image_archive_source: /tmp/zot.oci.tar",
            ),
        )
        result = run_build_publish_config(config, run_dir)
        if result.returncode == 0:
            raise AssertionError("offline image_archive_source was accepted")
        if "offline/local archive path inputs under build_flow were removed" not in result.stdout:
            raise AssertionError(result.stdout)


def test_rejects_skill_fixed_build_commands_and_sudo_flags() -> None:
    with tempfile.TemporaryDirectory(prefix="build-and-publish-config-") as tmp_dir:
        tmp = Path(tmp_dir)
        config = tmp / "config.yaml"
        run_dir = tmp / "run"
        write(
            config,
            MINIMAL_VALID_CONFIG.replace(
                "build_flow:",
                """build_flow:
  bootstrap_needs_sudo: true
  build_needs_sudo: true
  build_command: bash scripts/build-full-bundle.sh
  publish_command: bash scripts/publish-release.sh""",
            ),
        )
        result = run_build_publish_config(config, run_dir)
        if result.returncode == 0:
            raise AssertionError("skill-fixed build keys were accepted")
        if "build_command and build_flow.publish_command were removed" not in result.stdout and \
                "bootstrap_needs_sudo and build_flow.build_needs_sudo were removed" not in result.stdout:
            raise AssertionError(result.stdout)


def test_rejects_packaging_pin_keys() -> None:
    with tempfile.TemporaryDirectory(prefix="build-and-publish-config-") as tmp_dir:
        tmp = Path(tmp_dir)
        config = tmp / "config.yaml"
        run_dir = tmp / "run"
        write(
            config,
            MINIMAL_VALID_CONFIG.replace(
                "build_flow:",
                "build_flow:\n  argo:\n    enabled: true\n",
            ),
        )
        result = run_build_publish_config(config, run_dir)
        if result.returncode == 0:
            raise AssertionError("build_flow.argo pin keys were accepted")
        if "workflows engine/Zot/DNS/provisioner pin keys were removed" not in result.stdout:
            raise AssertionError(result.stdout)


def test_rejects_removed_build_publish_path_keys() -> None:
    removed_cases = [
        (
            "release_workspace.remote_repo_path",
            "  remote_repo_path: /tmp/appliance-release\n",
        ),
        (
            "release_workspace.remote_export_dir",
            "  remote_export_dir: /tmp/export\n",
        ),
    ]
    for label, snippet in removed_cases:
        with tempfile.TemporaryDirectory(prefix="build-and-publish-config-") as tmp_dir:
            tmp = Path(tmp_dir)
            config = tmp / "config.yaml"
            run_dir = tmp / "run"
            config_text = MINIMAL_VALID_CONFIG.replace(
                "  remote_build_root: /tmp/appliance-build\n",
                f"  remote_build_root: /tmp/appliance-build\n{snippet}",
            )
            write(config, config_text)
            result = run_build_publish_config(config, run_dir)
            if result.returncode == 0:
                raise AssertionError(f"{label} was accepted")
            if label not in result.stdout:
                raise AssertionError(f"expected rejection of {label}; got:\n{result.stdout}")
            if "release_workspace.remote_build_root" not in result.stdout:
                raise AssertionError(f"expected layout hint for remote_build_root; got:\n{result.stdout}")


def test_rejects_literal_image_tag() -> None:
    with tempfile.TemporaryDirectory(prefix="build-and-publish-config-") as tmp_dir:
        tmp = Path(tmp_dir)
        config = tmp / "config.yaml"
        run_dir = tmp / "run"
        write(
            config,
            MINIMAL_VALID_CONFIG.replace(
                "    image_tag_env: ONLINE_IMAGE_TAG",
                "    image_tag: latest",
            ),
        )
        result = run_build_publish_config(config, run_dir)
        if result.returncode == 0:
            raise AssertionError("literal image_tag was accepted")
        if "image_tag literal was removed" not in result.stdout:
            raise AssertionError(result.stdout)


def main() -> None:
    test_requires_local()
    test_rejects_legacy_dev_image_pull()
    test_rejects_literal_image_tag()
    test_rejects_missing_mode()
    test_rejects_removed_remote_release_input_and_bundle_overrides()
    test_rejects_offline_archive_path_inputs()
    test_rejects_skill_fixed_build_commands_and_sudo_flags()
    test_rejects_packaging_pin_keys()
    test_rejects_removed_build_publish_path_keys()
    print("build-and-publish config tests passed")


if __name__ == "__main__":
    main()
