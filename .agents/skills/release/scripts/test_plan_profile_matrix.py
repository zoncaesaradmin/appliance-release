#!/usr/bin/env python3
"""Local tests for plan-profile-matrix.py."""

import json
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[4]
PLANNER = ROOT / ".agents" / "skills" / "release" / "scripts" / "plan-profile-matrix.py"


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def run_planner(config: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["python3", str(PLANNER), "--config", str(config), *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def test_generates_profile_matrix_commands() -> None:
    with tempfile.TemporaryDirectory(prefix="profile-matrix-plan-") as tmp_dir:
        tmp = Path(tmp_dir)
        write(
            tmp / "catalog.yaml",
            """
workProfiles:
  - name: builder
    repos:
      - name: app
sourceCredentials:
  - id: git-main
    gitHost: git.internal.example.com
repos:
  - name: app
    url: git@git.internal.example.com:team/app.git
    sourceCredentialRef: git-main
buildTargets:
  - name: app
    repo: app
    execution: repo_script
    imageRepository: users/alice/app
    builderImageDigest: registry.local/buildah@sha256:abc123
""".lstrip(),
        )
        config = tmp / "config.yaml"
        write(
            config,
            f"""
release:
  version: 0.1.0
build_flow:
  extra_oci_image_refs: registry.local/buildah@sha256:abc123
install:
  build_catalog_path: {tmp / "catalog.yaml"}
client_verification:
  builder:
    workflow:
      enabled: true
      workspace_name: release-smoke
      work_profile: builder
      repo: app
      source_ref: 0123456789abcdef0123456789abcdef01234567
      target_name: app
      poll_attempts: 2
      poll_delay_seconds: 1
""".lstrip(),
        )
        plan_json = tmp / "profile-matrix-plan.json"
        plan_md = tmp / "profile-matrix-plan.md"
        result = run_planner(config, "--require-builder-workflow", "--output-json", str(plan_json), "--output-md", str(plan_md))
        if result.returncode != 0:
            raise AssertionError(result.stderr or result.stdout)
        plan = json.loads(result.stdout)
        commands = {item["profile"]: item for item in plan["commands"]}
        if not str(plan.get("generatedAt", "")).endswith("Z"):
            raise AssertionError(plan)
        if plan.get("buildCatalogPath") != str((tmp / "catalog.yaml").resolve()):
            raise AssertionError(plan)
        if "--skip-build" in commands["core"]["argv"]:
            raise AssertionError(commands["core"])
        for profile in ("storage", "builder"):
            if "--skip-build" not in commands[profile]["argv"]:
                raise AssertionError(commands[profile])
        if "--build-catalog" not in commands["builder"]["argv"]:
            raise AssertionError(commands["builder"])
        if plan["validationErrors"]:
            raise AssertionError(plan)
        if plan.get("suggestedConfigOverlay") is not None:
            raise AssertionError(plan)
        audit = plan.get("auditCommand") or {}
        if "audit-profile-matrix-reports.py" not in audit.get("command", ""):
            raise AssertionError(plan)
        if "--plan-json" not in audit.get("argv", []):
            raise AssertionError(plan)
        if "--require-builder-workflow" not in audit.get("argv", []):
            raise AssertionError(plan)
        checklist = "\n".join(plan.get("evidenceReviewChecklist", []))
        if "metadata/release-report.json" not in checklist or "optional workflow smoke succeeded" not in checklist:
            raise AssertionError(plan)
        markdown = plan_md.read_text(encoding="utf-8")
        if "Generated at:" not in markdown:
            raise AssertionError(markdown)
        if "## Resolved Inputs" not in markdown or str((tmp / "catalog.yaml").resolve()) not in markdown:
            raise AssertionError(markdown)
        if "## Post-Run Audit Command" not in markdown or "audit-profile-matrix-reports.py" not in markdown:
            raise AssertionError(markdown)
        if "## Evidence Review Checklist" not in markdown or "release-report.md" not in markdown:
            raise AssertionError(markdown)


def test_require_builder_workflow_reports_missing_config() -> None:
    with tempfile.TemporaryDirectory(prefix="profile-matrix-plan-") as tmp_dir:
        tmp = Path(tmp_dir)
        config = tmp / "config.yaml"
        write(config, "release:\n  version: 0.1.0\n")
        result = run_planner(config, "--require-builder-workflow")
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
        config = tmp / "config.yaml"
        output_md = tmp / "checklist.md"
        write(config, "release:\n  version: 0.1.0\n")
        result = run_planner(
            config,
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
        if "not a live run plan" not in "\n".join(plan.get("notes") or []):
            raise AssertionError(plan)
        overlay = str(plan.get("suggestedConfigOverlay") or "")
        if "install:" not in overlay or "client_verification:" not in overlay:
            raise AssertionError(plan)
        if ".agents/skills/release/references/build-catalog.example.yaml" not in overlay:
            raise AssertionError(plan)
        if "source_ref: 0123456789abcdef0123456789abcdef01234567" not in overlay:
            raise AssertionError(plan)
        if "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" not in overlay:
            raise AssertionError(plan)
        if "privateKey:" in overlay or "token:" in overlay or "password:" in overlay:
            raise AssertionError(plan)
        markdown = output_md.read_text(encoding="utf-8")
        if "# Final Profile Input Checklist" not in markdown:
            raise AssertionError(markdown)
        if "Do not run the live profile matrix from this checklist" not in markdown:
            raise AssertionError(markdown)
        if "Use final-profile-matrix-plan.md" not in markdown:
            raise AssertionError(markdown)
        if "## Suggested Config Overlay" not in markdown or "```yaml" not in markdown:
            raise AssertionError(markdown)
        if "## Commands" in markdown or "## Post-Run Audit Command" in markdown:
            raise AssertionError(markdown)

def test_build_catalog_requires_extra_oci_image_ref() -> None:
    with tempfile.TemporaryDirectory(prefix="profile-matrix-plan-") as tmp_dir:
        tmp = Path(tmp_dir)
        write(
            tmp / "catalog.yaml",
            """
buildTargets:
  - name: app
    execution: repo_script
    imageRepository: users/alice/app
    builderImageDigest: registry.local/buildah@sha256:abc123
""".lstrip(),
        )
        config = tmp / "config.yaml"
        write(
            config,
            f"""
build_flow:
  extra_oci_image_refs: registry.local/other@sha256:def456
install:
  build_catalog_path: {tmp / "catalog.yaml"}
""".lstrip(),
        )
        result = run_planner(config)
        if result.returncode == 0:
            raise AssertionError("unbundled builder image ref was accepted")
        plan = json.loads(result.stdout)
        joined = "\n".join(plan["validationErrors"])
        if "build_flow.extra_oci_image_refs" not in joined:
            raise AssertionError(plan)

def test_build_catalog_workflow_smoke_names_must_exist() -> None:
    with tempfile.TemporaryDirectory(prefix="profile-matrix-plan-") as tmp_dir:
        tmp = Path(tmp_dir)
        write(
            tmp / "catalog.yaml",
            """
workProfiles:
  - name: builder
    repos:
      - name: app
repos:
  - name: app
    url: https://git.internal.example.com/team/app.git
buildTargets:
  - name: default
    repo: app
    execution: repo_script
    imageRepository: users/alice/app
    builderImageDigest: registry.local/buildah@sha256:abc123
""".lstrip(),
        )
        config = tmp / "config.yaml"
        write(
            config,
            f"""
build_flow:
  extra_oci_image_refs: registry.local/buildah@sha256:abc123
install:
  build_catalog_path: {tmp / "catalog.yaml"}
client_verification:
  builder:
    workflow:
      enabled: true
      workspace_name: release-smoke
      work_profile: builder
      repo: app
      source_ref: 0123456789abcdef0123456789abcdef01234567
      target_name: missing
""".lstrip(),
        )
        result = run_planner(config)
        if result.returncode == 0:
            raise AssertionError("unknown workflow target_name was accepted")
        plan = json.loads(result.stdout)
        joined = "\n".join(plan["validationErrors"])
        if "target_name is not declared" not in joined:
            raise AssertionError(plan)


def test_build_catalog_workflow_smoke_accepts_target_alias() -> None:
    with tempfile.TemporaryDirectory(prefix="profile-matrix-plan-") as tmp_dir:
        tmp = Path(tmp_dir)
        write(
            tmp / "catalog.yaml",
            """
workProfiles:
  - name: builder
    repos:
      - name: app
repos:
  - name: app
    url: https://git.internal.example.com/team/app.git
buildTargets:
  - name: default
    aliases:
      - app
    repo: app
    execution: repo_script
    imageRepository: users/alice/app
    builderImageDigest: registry.local/buildah@sha256:abc123
""".lstrip(),
        )
        config = tmp / "config.yaml"
        write(
            config,
            f"""
build_flow:
  extra_oci_image_refs: registry.local/buildah@sha256:abc123
install:
  build_catalog_path: {tmp / "catalog.yaml"}
client_verification:
  builder:
    workflow:
      enabled: true
      workspace_name: release-smoke
      work_profile: builder
      repo: app
      source_ref: 0123456789abcdef0123456789abcdef01234567
      target_name: app
""".lstrip(),
        )
        result = run_planner(config)
        if result.returncode != 0:
            raise AssertionError(result.stderr or result.stdout)
        plan = json.loads(result.stdout)
        if plan["validationErrors"]:
            raise AssertionError(plan)


def test_build_catalog_repos_must_reference_known_source_credentials() -> None:
    with tempfile.TemporaryDirectory(prefix="profile-matrix-plan-") as tmp_dir:
        tmp = Path(tmp_dir)
        write(
            tmp / "catalog.yaml",
            """
sourceCredentials:
  - id: git-main
    gitHost: git.internal.example.com
repos:
  - name: app
    url: https://git.internal.example.com/team/app.git
    sourceCredentialRef: missing-credential
buildTargets:
  - name: app
    repo: app
    execution: repo_script
    imageRepository: users/alice/app
    builderImageDigest: registry.local/buildah@sha256:abc123
""".lstrip(),
        )
        config = tmp / "config.yaml"
        write(
            config,
            f"""
build_flow:
  extra_oci_image_refs: registry.local/buildah@sha256:abc123
install:
  build_catalog_path: {tmp / "catalog.yaml"}
""".lstrip(),
        )
        result = run_planner(config)
        if result.returncode == 0:
            raise AssertionError("unknown repo sourceCredentialRef was accepted")
        plan = json.loads(result.stdout)
        joined = "\n".join(plan["validationErrors"])
        if "sourceCredentialRef references unknown" not in joined:
            raise AssertionError(plan)

def test_build_catalog_ssh_repo_requires_source_credential_ref() -> None:
    with tempfile.TemporaryDirectory(prefix="profile-matrix-plan-") as tmp_dir:
        tmp = Path(tmp_dir)
        write(
            tmp / "catalog.yaml",
            """
repos:
  - name: app
    url: git@git.internal.example.com:team/app.git
buildTargets:
  - name: app
    repo: app
    execution: repo_script
    imageRepository: users/alice/app
    builderImageDigest: registry.local/buildah@sha256:abc123
""".lstrip(),
        )
        config = tmp / "config.yaml"
        write(
            config,
            f"""
build_flow:
  extra_oci_image_refs: registry.local/buildah@sha256:abc123
install:
  build_catalog_path: {tmp / "catalog.yaml"}
""".lstrip(),
        )
        result = run_planner(config)
        if result.returncode == 0:
            raise AssertionError("SSH repo without sourceCredentialRef was accepted")
        plan = json.loads(result.stdout)
        joined = "\n".join(plan["validationErrors"])
        if "sourceCredentialRef is required for SSH repo URLs" not in joined:
            raise AssertionError(plan)


def test_build_catalog_make_target_requires_make_target_name() -> None:
    with tempfile.TemporaryDirectory(prefix="profile-matrix-plan-") as tmp_dir:
        tmp = Path(tmp_dir)
        write(
            tmp / "catalog.yaml",
            """
repos:
  - name: app
    url: https://git.internal.example.com/team/app.git
buildTargets:
  - name: app
    repo: app
    execution: make_target
    imageRepository: users/alice/app
    builderImageDigest: registry.local/buildah@sha256:abc123
""".lstrip(),
        )
        config = tmp / "config.yaml"
        write(
            config,
            f"""
build_flow:
  extra_oci_image_refs: registry.local/buildah@sha256:abc123
install:
  build_catalog_path: {tmp / "catalog.yaml"}
""".lstrip(),
        )
        result = run_planner(config)
        if result.returncode == 0:
            raise AssertionError("make_target execution without makeTarget was accepted")
        plan = json.loads(result.stdout)
        joined = "\n".join(plan["validationErrors"])
        if "makeTarget is required" not in joined:
            raise AssertionError(plan)


def test_build_catalog_rejects_unsafe_execution_paths() -> None:
    cases = [
        ("scriptPath", "/tmp/build.sh", "repo_script", "scriptPath must be a relative path inside the repo"),
        ("scriptPath", "../build.sh", "repo_script", "scriptPath must be a relative path inside the repo"),
        ("containerfilePath", "deploy/../../Containerfile", "repo_script", "containerfilePath must be a relative path inside the repo"),
        ("makeTarget", "image && whoami", "make_target", "makeTarget contains unsupported characters"),
    ]
    for field, value, execution, expected in cases:
        with tempfile.TemporaryDirectory(prefix="profile-matrix-plan-") as tmp_dir:
            tmp = Path(tmp_dir)
            extra = f"    {field}: {value}\n"
            write(
                tmp / "catalog.yaml",
                f"""
repos:
  - name: app
    url: https://git.internal.example.com/team/app.git
buildTargets:
  - name: app
    repo: app
    execution: {execution}
{extra}    imageRepository: users/alice/app
    builderImageDigest: registry.local/buildah@sha256:abc123
""".lstrip(),
            )
            config = tmp / "config.yaml"
            write(
                config,
                f"""
build_flow:
  extra_oci_image_refs: registry.local/buildah@sha256:abc123
install:
  build_catalog_path: {tmp / "catalog.yaml"}
""".lstrip(),
            )
            result = run_planner(config)
            if result.returncode == 0:
                raise AssertionError(f"unsafe catalog value {field}={value!r} was accepted")
            plan = json.loads(result.stdout)
            joined = "\n".join(plan["validationErrors"])
            if expected not in joined:
                raise AssertionError(plan)


def test_reference_builder_templates_are_planner_compatible() -> None:
    catalog = ROOT / ".agents" / "skills" / "release" / "references" / "build-catalog.example.yaml"
    with tempfile.TemporaryDirectory(prefix="profile-matrix-plan-") as tmp_dir:
        tmp = Path(tmp_dir)
        config = tmp / "config.yaml"
        write(
            config,
            f"""
release:
  version: 0.1.0
build_flow:
  extra_oci_image_refs: registry.local/buildah@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
install:
  build_catalog_path: {catalog}
client_verification:
  builder:
    workflow:
      enabled: true
      workspace_name: release-smoke
      work_profile: platform-dev
      repo: platformkit
      source_ref: 0123456789abcdef0123456789abcdef01234567
      target_name: platform
      poll_attempts: 2
      poll_delay_seconds: 1
""".lstrip(),
        )
        result = run_planner(config, "--require-builder-workflow")
        if result.returncode != 0:
            raise AssertionError(result.stderr or result.stdout)
        plan = json.loads(result.stdout)
        if plan["validationErrors"]:
            raise AssertionError(plan)


def main() -> None:
    test_generates_profile_matrix_commands()
    test_require_builder_workflow_reports_missing_config()
    test_checklist_mode_suppresses_runnable_commands_when_incomplete()
    test_build_catalog_requires_extra_oci_image_ref()
    test_build_catalog_workflow_smoke_names_must_exist()
    test_build_catalog_workflow_smoke_accepts_target_alias()
    test_build_catalog_repos_must_reference_known_source_credentials()
    test_build_catalog_ssh_repo_requires_source_credential_ref()
    test_build_catalog_make_target_requires_make_target_name()
    test_build_catalog_rejects_unsafe_execution_paths()
    test_reference_builder_templates_are_planner_compatible()
    print("plan-profile-matrix tests passed")


if __name__ == "__main__":
    main()
