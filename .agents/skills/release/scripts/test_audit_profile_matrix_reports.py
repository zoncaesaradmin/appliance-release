#!/usr/bin/env python3
"""Local tests for audit-profile-matrix-reports.py."""

import json
import subprocess
import tempfile
from pathlib import Path
from typing import Optional


ROOT = Path(__file__).resolve().parents[4]
AUDITOR = ROOT / ".agents" / "skills" / "release" / "scripts" / "audit-profile-matrix-reports.py"


def write_report(
    run_dir: Path,
    profile: str,
    *,
    workflow: bool = False,
    build_catalog_path: Optional[Path] = None,
    bad: Optional[dict] = None,
) -> None:
    builder_tools = [
        "list_work_profiles",
        "get_workspace",
        "set_workspace",
        "list_build_targets",
        "submit_build",
        "list_jobs",
        "get_job_status",
        "get_job_steps",
        "get_job_logs",
        "cancel_job",
    ]
    client = {
        "status": "passed",
        "builderToolsPresent": builder_tools if profile == "builder" else [],
        "disabledBuildUnexpectedTools": [],
        "disabledBuildDirectToolCall": {
            "statusCode": 200,
            "expectedJSONRPCError": {"code": -32601, "message": "Tool not found"},
        }
        if profile != "builder"
        else None,
        "workflow": {
            "enabled": workflow,
            "jobId": "job-1" if workflow else None,
            "finalStatus": "succeeded" if workflow else None,
            "artifactRef": "users/alice/app:v1" if workflow else None,
            "secretLeakCheckPassed": True if workflow else None,
        },
        "artifact": {
            "enabled": profile in {"storage", "builder"},
            "catalogStatusCode": 200 if profile in {"storage", "builder"} else 404,
            "catalogFiltered": True if profile in {"storage", "builder"} else False,
            "anonymousCatalogStatusCode": 401 if profile in {"storage", "builder"} else 404,
            "v2ChallengeStatusCode": 401 if profile in {"storage", "builder"} else 404,
            "tokenIssuanceStatusCode": 200 if profile in {"storage", "builder"} else None,
            "deniedScopeStatusCode": 200 if profile in {"storage", "builder"} else None,
            "deniedScopeGranted": False if profile in {"storage", "builder"} else None,
            "malformedTokenStatusCode": 401 if profile in {"storage", "builder"} else None,
            "tokenRevokeStatusCode": 204 if profile in {"storage", "builder"} else None,
            "revokedCredentialStatusCode": 401 if profile in {"storage", "builder"} else None,
            "revokedTokenChecked": True if profile in {"storage", "builder"} else None,
            "ociSmoke": {"configured": False},
            "orasSmoke": {"configured": False},
            "offlineSmoke": {"configured": False},
        },
    }
    report = {
        "overallStatus": "passed",
        "releaseVersion": "0.1.0",
        "applianceProfile": profile,
        "buildCatalogPath": str(build_catalog_path) if build_catalog_path else None,
        "steps": {
            "buildPublish": {"status": "passed" if profile == "core" else "skipped"},
            "install": {"status": "passed"},
            "targetVerify": {
                "status": "passed",
                "artifact": {
                    "enabled": profile in {"storage", "builder"},
                    "readinessExitCode": 0 if profile in {"storage", "builder"} else None,
                },
            },
            "clientVerify": {
                **client,
                "builderWorkProfilesStatusCode": 200 if profile == "builder" else None,
                "disabledBuildWorkProfilesStatusCode": 404 if profile != "builder" else None,
            },
        },
    }
    if bad:
        for key, value in bad.items():
            if key == "client":
                report["steps"]["clientVerify"].update(value)
            else:
                report[key] = value
    path = run_dir / "metadata" / "release-report.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    (run_dir / "release-report.md").write_text("# Appliance Release Report\n", encoding="utf-8")


def run_auditor(core: Path, storage: Path, builder: Path, *extra: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [
            "python3",
            str(AUDITOR),
            "--core-run-dir",
            str(core),
            "--storage-run-dir",
            str(storage),
            "--builder-run-dir",
            str(builder),
            *extra,
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def write_plan(
    path: Path,
    *,
    release_version: str = "0.1.0",
    require_workflow: bool = False,
    build_catalog_path: Optional[Path] = None,
) -> None:
    payload = {
        "releaseVersion": release_version,
        "buildCatalogPath": str(build_catalog_path) if build_catalog_path else None,
        "profiles": ["core", "storage", "builder"],
        "auditCommand": {"requiresBuilderWorkflow": require_workflow},
    }
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def test_passes_complete_matrix_with_workflow() -> None:
    with tempfile.TemporaryDirectory(prefix="profile-matrix-audit-") as tmp_dir:
        root = Path(tmp_dir)
        core, storage, builder = root / "core", root / "storage", root / "builder"
        write_report(core, "core")
        write_report(storage, "storage")
        write_report(builder, "builder", workflow=True)
        result = run_auditor(core, storage, builder, "--require-builder-workflow")
        if result.returncode != 0:
            raise AssertionError(result.stderr or result.stdout)
        summary = json.loads(result.stdout)
        if summary["status"] != "passed":
            raise AssertionError(summary)
        if not str(summary.get("generatedAt", "")).endswith("Z"):
            raise AssertionError(summary)


def test_plan_json_requires_builder_workflow_and_matching_version() -> None:
    with tempfile.TemporaryDirectory(prefix="profile-matrix-audit-") as tmp_dir:
        root = Path(tmp_dir)
        core, storage, builder = root / "core", root / "storage", root / "builder"
        write_report(core, "core")
        write_report(storage, "storage")
        write_report(builder, "builder", workflow=False)
        plan = root / "plan.json"
        write_plan(plan, release_version="0.2.0", require_workflow=True)
        result = run_auditor(core, storage, builder, "--plan-json", str(plan))
        if result.returncode == 0:
            raise AssertionError("plan mismatch and required workflow were accepted")
        summary = json.loads(result.stdout)
        errors = "\n".join(summary["errors"])
        if "releaseVersion is '0.1.0', want plan releaseVersion '0.2.0'" not in errors:
            raise AssertionError(summary)
        if "workflow smoke evidence is missing" not in errors:
            raise AssertionError(summary)
        if summary.get("planRequiresBuilderWorkflow") is not True:
            raise AssertionError(summary)


def test_plan_json_requires_matching_builder_config_inputs() -> None:
    with tempfile.TemporaryDirectory(prefix="profile-matrix-audit-") as tmp_dir:
        root = Path(tmp_dir)
        core, storage, builder = root / "core", root / "storage", root / "builder"
        expected_catalog = root / "catalog.yaml"
        wrong_catalog = root / "wrong-catalog.yaml"
        write_report(core, "core", build_catalog_path=expected_catalog)
        write_report(storage, "storage", build_catalog_path=expected_catalog)
        write_report(
            builder,
            "builder",
            workflow=True,
            build_catalog_path=wrong_catalog,
        )
        plan = root / "plan.json"
        write_plan(plan, build_catalog_path=expected_catalog)
        result = run_auditor(core, storage, builder, "--plan-json", str(plan), "--require-builder-workflow")
        if result.returncode == 0:
            raise AssertionError("builder report with wrong build catalog was accepted")
        summary = json.loads(result.stdout)
        if "builder: buildCatalogPath" not in "\n".join(summary["errors"]):
            raise AssertionError(summary)


def test_fails_when_non_builder_exposes_build_tools() -> None:
    with tempfile.TemporaryDirectory(prefix="profile-matrix-audit-") as tmp_dir:
        root = Path(tmp_dir)
        core, storage, builder = root / "core", root / "storage", root / "builder"
        write_report(core, "core", bad={"client": {"disabledBuildUnexpectedTools": ["submit_build"]}})
        write_report(storage, "storage")
        write_report(builder, "builder", workflow=True)
        result = run_auditor(core, storage, builder, "--require-builder-workflow")
        if result.returncode == 0:
            raise AssertionError("unexpected builder tool exposure was accepted")
        summary = json.loads(result.stdout)
        if "disabled builder MCP tools" not in "\n".join(summary["errors"]):
            raise AssertionError(summary)


def test_fails_when_disabled_build_route_is_registered() -> None:
    with tempfile.TemporaryDirectory(prefix="profile-matrix-audit-") as tmp_dir:
        root = Path(tmp_dir)
        core, storage, builder = root / "core", root / "storage", root / "builder"
        write_report(core, "core", bad={"client": {"disabledBuildWorkProfilesStatusCode": 200}})
        write_report(storage, "storage")
        write_report(builder, "builder", workflow=True)
        result = run_auditor(core, storage, builder, "--require-builder-workflow")
        if result.returncode == 0:
            raise AssertionError("registered disabled build route was accepted")
        summary = json.loads(result.stdout)
        if "disabled /api/v1/work-profiles status" not in "\n".join(summary["errors"]):
            raise AssertionError(summary)


def test_fails_when_builder_route_is_missing() -> None:
    with tempfile.TemporaryDirectory(prefix="profile-matrix-audit-") as tmp_dir:
        root = Path(tmp_dir)
        core, storage, builder = root / "core", root / "storage", root / "builder"
        write_report(core, "core")
        write_report(storage, "storage")
        write_report(builder, "builder", workflow=True, bad={"client": {"builderWorkProfilesStatusCode": 404}})
        result = run_auditor(core, storage, builder, "--require-builder-workflow")
        if result.returncode == 0:
            raise AssertionError("missing builder build route was accepted")
        summary = json.loads(result.stdout)
        if "builder: /api/v1/work-profiles status" not in "\n".join(summary["errors"]):
            raise AssertionError(summary)


def test_fails_when_required_builder_workflow_missing() -> None:
    with tempfile.TemporaryDirectory(prefix="profile-matrix-audit-") as tmp_dir:
        root = Path(tmp_dir)
        core, storage, builder = root / "core", root / "storage", root / "builder"
        write_report(core, "core")
        write_report(storage, "storage")
        write_report(builder, "builder", workflow=False)
        result = run_auditor(core, storage, builder, "--require-builder-workflow")
        if result.returncode == 0:
            raise AssertionError("missing builder workflow evidence was accepted")
        summary = json.loads(result.stdout)
        if "workflow smoke evidence is missing" not in "\n".join(summary["errors"]):
            raise AssertionError(summary)


def test_fails_when_markdown_report_is_missing() -> None:
    with tempfile.TemporaryDirectory(prefix="profile-matrix-audit-") as tmp_dir:
        root = Path(tmp_dir)
        core, storage, builder = root / "core", root / "storage", root / "builder"
        write_report(core, "core")
        write_report(storage, "storage")
        write_report(builder, "builder", workflow=True)
        (storage / "release-report.md").unlink()
        result = run_auditor(core, storage, builder, "--require-builder-workflow")
        if result.returncode == 0:
            raise AssertionError("missing markdown report was accepted")
        summary = json.loads(result.stdout)
        if "missing markdown release report" not in "\n".join(summary["errors"]):
            raise AssertionError(result.stderr or result.stdout)


def test_fails_when_matrix_step_pattern_is_wrong() -> None:
    with tempfile.TemporaryDirectory(prefix="profile-matrix-audit-") as tmp_dir:
        root = Path(tmp_dir)
        core, storage, builder = root / "core", root / "storage", root / "builder"
        write_report(core, "core")
        write_report(storage, "storage", bad={"steps": {"buildPublish": {"status": "passed"}, "install": {"status": "passed"}, "targetVerify": {"status": "passed"}, "clientVerify": {"status": "passed"}}})
        write_report(builder, "builder", workflow=True)
        result = run_auditor(core, storage, builder, "--require-builder-workflow")
        if result.returncode == 0:
            raise AssertionError("wrong storage buildPublish status was accepted")
        summary = json.loads(result.stdout)
        if "storage: step buildPublish status is 'passed', want 'skipped'" not in "\n".join(summary["errors"]):
            raise AssertionError(summary)


def test_failure_writes_output_json_with_all_load_errors() -> None:
    with tempfile.TemporaryDirectory(prefix="profile-matrix-audit-") as tmp_dir:
        root = Path(tmp_dir)
        core, storage, builder = root / "core", root / "storage", root / "builder"
        write_report(core, "core")
        write_report(storage, "storage")
        (storage / "release-report.md").unlink()
        out = root / "audit.json"
        result = run_auditor(core, storage, builder, "--output-json", str(out))
        if result.returncode == 0:
            raise AssertionError("missing reports were accepted")
        if not out.is_file():
            raise AssertionError("expected failed audit to write output JSON")
        summary = json.loads(out.read_text(encoding="utf-8"))
        errors = "\n".join(summary["errors"])
        if "storage: missing markdown release report" not in errors or "builder: missing release report" not in errors:
            raise AssertionError(summary)


def main() -> None:
    test_passes_complete_matrix_with_workflow()
    test_plan_json_requires_builder_workflow_and_matching_version()
    test_plan_json_requires_matching_builder_config_inputs()
    test_fails_when_non_builder_exposes_build_tools()
    test_fails_when_disabled_build_route_is_registered()
    test_fails_when_builder_route_is_missing()
    test_fails_when_required_builder_workflow_missing()
    test_fails_when_markdown_report_is_missing()
    test_fails_when_matrix_step_pattern_is_wrong()
    test_failure_writes_output_json_with_all_load_errors()
    print("audit-profile-matrix-reports tests passed")


if __name__ == "__main__":
    main()
