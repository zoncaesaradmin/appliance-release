#!/usr/bin/env python3
"""Local tests for plan-profile-matrix.py (three-config orchestrator)."""

import json
import subprocess
import tempfile
from pathlib import Path
from typing import Optional, Tuple


ROOT = Path(__file__).resolve().parents[4]
PLANNER = ROOT / ".agents" / "skills" / "release" / "scripts" / "plan-profile-matrix.py"


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def write_role_configs(
    tmp: Path,
    *,
    catalog: Optional[Path] = None,
    with_workflow: bool = False,
) -> Tuple[Path, Path, Path]:
    mac = tmp / "mac.yaml"
    build = tmp / "build.yaml"
    install = tmp / "install.yaml"
    write(
        mac,
        """
build_host:
  alias: build@example
target_host:
  alias: target@example
  state_dir: /var/lib/zon/state
report:
  final_ok: false
""".lstrip(),
    )
    write(
        build,
        """
release_workspace:
  remote_repo_path: /tmp/ws
  remote_repo_source: https://example.com/r.git
  remote_repo_ref: main
  remote_export_dir: /tmp/export
release:
  version: 0.1.0
  publish_latest_alias: false
build_flow:
  skip: false
  code_repo_ref: main
  ctl_repo_ref: main
  k3s_binary_source: /tmp/k3s
  k3s_airgap_images_source: /tmp/k3s-airgap
  bootstrap_needs_sudo: false
  build_needs_sudo: false
  build_command: bash scripts/ci/build-full-bundle.sh
  publish_command: make publish-release
  dev_image_pull:
    registry_env: DEV_REGISTRY
    image_repo_env: DEV_IMAGE_REPO
    image_name_env: DEV_IMAGE_NAME
    image_tag: latest
    username_env: DEV_REGISTRY_USER
    token_env: DEV_REGISTRY_TOKEN
    tls_verify_env: DEV_REGISTRY_TLS_VERIFY
bundle_store:
  mode: static_http
  release_path_prefix: appliance
  base_url: http://example:9
""".lstrip(),
    )
    catalog_line = f"  build_catalog_path: {catalog}\n" if catalog else ""
    if with_workflow and catalog is not None:
        workflow_block = """
    workflow:
      enabled: true
      workspace_name: release-smoke
      work_profile: builder
      repo: app
      source_ref: 0123456789abcdef0123456789abcdef01234567
      target_name: app
      poll_attempts: 2
      poll_delay_seconds: 1
"""
    else:
        workflow_block = ""
    write(
        install,
        f"""
install:
  skip: false
  uninstall_first: false
  preserve_failed_state: false
  bootstrap_admin: false
  enable_default_license: false
  appliance_name: n
  dns_zone: z
  appliance_profile: core
  bundle_download_dir: /tmp/a
{catalog_line}verification:
  status_command: true
  argo:
    enabled: false
  builder:
    enabled: false
  artifact:
    enabled: false
  dns:
    enabled: false
client_verification:
  base_url: https://n.z
  username: admin
  builder:
    enabled: false
    expect_disabled: true
{workflow_block}  artifact:
    enabled: false
""".lstrip(),
    )
    return mac, build, install


def run_planner(mac: Path, build: Path, install: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [
            "python3",
            str(PLANNER),
            "--config",
            str(mac),
            "--build-publish-config",
            str(build),
            "--install-config",
            str(install),
            *args,
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def test_generates_profile_matrix_commands() -> None:
    with tempfile.TemporaryDirectory(prefix="profile-matrix-plan-") as tmp_dir:
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
buildTargets:
  - name: app
    repo: app
    execution: script
    args: [build.sh]
    imageRepository: users/alice/app
""".lstrip(),
        )
        mac, build, install = write_role_configs(tmp, catalog=catalog, with_workflow=True)
        plan_json = tmp / "profile-matrix-plan.json"
        plan_md = tmp / "profile-matrix-plan.md"
        result = run_planner(
            mac,
            build,
            install,
            "--require-builder-workflow",
            "--output-json",
            str(plan_json),
            "--output-md",
            str(plan_md),
        )
        if result.returncode != 0:
            raise AssertionError(result.stderr or result.stdout)
        plan = json.loads(result.stdout)
        commands = {item["profile"]: item for item in plan["commands"]}
        if commands["core"]["configOverrides"].get("build_flow.skip") is not False:
            raise AssertionError(commands["core"])
        for profile in ("storage", "builder"):
            if commands[profile]["configOverrides"].get("build_flow.skip") is not True:
                raise AssertionError(commands[profile])
        if commands["builder"]["configOverrides"].get("install.build_catalog_path") is None:
            raise AssertionError(commands["builder"])
        if "--build-publish-config" not in commands["core"]["argv"]:
            raise AssertionError(commands["core"])
        if plan["validationErrors"]:
            raise AssertionError(plan)
        audit = plan.get("auditCommand") or {}
        if "audit-profile-matrix-reports.py" not in audit.get("command", ""):
            raise AssertionError(plan)
        markdown = plan_md.read_text(encoding="utf-8")
        if "## Resolved Inputs" not in markdown or str(catalog.resolve()) not in markdown:
            raise AssertionError(markdown)


def test_require_builder_workflow_reports_missing_config() -> None:
    with tempfile.TemporaryDirectory(prefix="profile-matrix-plan-") as tmp_dir:
        tmp = Path(tmp_dir)
        mac, build, install = write_role_configs(tmp)
        result = run_planner(mac, build, install, "--require-builder-workflow")
        if result.returncode == 0:
            raise AssertionError("missing builder workflow config was accepted")
        plan = json.loads(result.stdout)
        joined = "\n".join(plan["validationErrors"])
        if "client_verification.builder.workflow.enabled" not in joined:
            raise AssertionError(plan)
        if "install.build_catalog_path" not in joined:
            raise AssertionError(plan)


def test_checklist_mode_suppresses_runnable_commands_when_incomplete() -> None:
    with tempfile.TemporaryDirectory(prefix="profile-matrix-plan-") as tmp_dir:
        tmp = Path(tmp_dir)
        mac, build, install = write_role_configs(tmp)
        output_md = tmp / "checklist.md"
        result = run_planner(
            mac,
            build,
            install,
            "--require-builder-workflow",
            "--checklist-only",
            "--document-title",
            "Final Profile Input Checklist",
            "--output-md",
            str(output_md),
        )
        if result.returncode == 0:
            raise AssertionError("incomplete final checklist unexpectedly passed")
        plan = json.loads(result.stdout)
        if plan.get("checklistOnly") is not True or plan.get("readyForFinalPlan") is not False:
            raise AssertionError(plan)
        if plan.get("commands") != [] or plan.get("auditCommand") is not None:
            raise AssertionError(plan)
        markdown = output_md.read_text(encoding="utf-8")
        if "# Final Profile Input Checklist" not in markdown:
            raise AssertionError(markdown)
        if "## Commands" in markdown:
            raise AssertionError(markdown)


def main() -> None:
    test_generates_profile_matrix_commands()
    test_require_builder_workflow_reports_missing_config()
    test_checklist_mode_suppresses_runnable_commands_when_incomplete()
    print("plan-profile-matrix tests passed")


if __name__ == "__main__":
    main()
