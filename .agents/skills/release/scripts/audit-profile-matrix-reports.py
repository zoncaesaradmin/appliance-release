#!/usr/bin/env python3
"""Audit generated release reports after the real profile-matrix runs."""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
from typing import Any


EXPECTED_BUILDER_TOOLS = {
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
}


def read_report(run_dir: Path) -> dict[str, Any]:
    report_path = run_dir / "metadata" / "release-report.json"
    if not report_path.is_file():
        raise ValueError(f"missing release report: {report_path}")
    markdown_path = run_dir / "release-report.md"
    if not markdown_path.is_file():
        raise ValueError(f"missing markdown release report: {markdown_path}")
    with report_path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"{report_path} must contain a JSON object")
    data["_runDir"] = str(run_dir)
    data["_reportPath"] = str(report_path)
    data["_markdownPath"] = str(markdown_path)
    return data


def read_plan(path: str) -> dict[str, Any]:
    if not path:
        return {}
    plan_path = Path(path)
    if not plan_path.is_file():
        raise ValueError(f"missing profile matrix plan: {plan_path}")
    with plan_path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"{plan_path} must contain a JSON object")
    data["_planPath"] = str(plan_path)
    return data


def step_statuses(report: dict[str, Any]) -> dict[str, str]:
    steps = report.get("steps")
    if not isinstance(steps, dict):
        return {}
    out: dict[str, str] = {}
    for name, step in steps.items():
        if isinstance(step, dict):
            out[name] = str(step.get("status") or "")
    return out


def step(report: dict[str, Any], name: str) -> dict[str, Any]:
    steps = report.get("steps")
    if not isinstance(steps, dict):
        return {}
    value = steps.get(name)
    return value if isinstance(value, dict) else {}


def profile_name(report: dict[str, Any], fallback: str) -> str:
    raw = str(report.get("applianceProfile") or "").strip()
    return raw or fallback


def normalized_path(raw: Any) -> str:
    value = str(raw or "").strip()
    if not value:
        return ""
    return str(Path(value).expanduser().resolve())


def audit_common(profile: str, report: dict[str, Any], errors: list[str]) -> None:
    label = f"{profile}:"
    if report.get("overallStatus") != "passed":
        errors.append(f"{label} overallStatus is {report.get('overallStatus')!r}, want 'passed'")
    if profile_name(report, profile) != profile:
        errors.append(f"{label} applianceProfile is {profile_name(report, profile)!r}, want {profile!r}")
    expected_statuses = {
        "buildPublish": "passed" if profile == "core" else "skipped",
        "install": "passed",
        "targetVerify": "passed",
        "clientVerify": "passed",
    }
    statuses = step_statuses(report)
    for name, expected in expected_statuses.items():
        actual = statuses.get(name)
        if actual != expected:
            errors.append(f"{label} step {name} status is {actual!r}, want {expected!r}")


def audit_non_builder(profile: str, report: dict[str, Any], errors: list[str]) -> None:
    client = step(report, "clientVerify")
    route_code = client.get("disabledBuildWorkProfilesStatusCode")
    if route_code != 404:
        errors.append(f"{profile}: disabled /api/v1/work-profiles status is {route_code!r}, want 404")
    unexpected = client.get("disabledBuildUnexpectedTools")
    if unexpected not in ([], None):
        errors.append(f"{profile}: disabled builder MCP tools were exposed: {unexpected}")
    direct = client.get("disabledBuildDirectToolCall")
    if not isinstance(direct, dict):
        errors.append(f"{profile}: missing disabled direct MCP tool-call evidence")
        return
    if direct.get("statusCode") != 200:
        errors.append(f"{profile}: disabled direct MCP tool-call HTTP status is {direct.get('statusCode')!r}, want 200")
    expected = direct.get("expectedJSONRPCError")
    if not isinstance(expected, dict) or expected.get("code") != -32601 or expected.get("message") != "Tool not found":
        errors.append(f"{profile}: disabled direct MCP tool-call expected error is {expected!r}, want tool-not-found")


def audit_builder(report: dict[str, Any], require_workflow: bool, errors: list[str]) -> None:
    client = step(report, "clientVerify")
    route_code = client.get("builderWorkProfilesStatusCode")
    if not isinstance(route_code, int) or route_code >= 400:
        errors.append(f"builder: /api/v1/work-profiles status is {route_code!r}, want <400")
    tools = set(client.get("builderToolsPresent") or [])
    missing = sorted(EXPECTED_BUILDER_TOOLS - tools)
    if missing:
        errors.append(f"builder: missing MCP builder tools: {missing}")
    workflow = client.get("workflow")
    workflow = workflow if isinstance(workflow, dict) else {}
    if require_workflow:
        if workflow.get("enabled") is not True:
            errors.append("builder: workflow smoke evidence is missing")
            return
        if workflow.get("finalStatus") != "succeeded":
            errors.append(f"builder: workflow finalStatus is {workflow.get('finalStatus')!r}, want 'succeeded'")
        if not str(workflow.get("artifactRef") or "").strip():
            errors.append("builder: workflow artifactRef is missing")
        if workflow.get("secretLeakCheckPassed") is not True:
            errors.append("builder: workflow secret leak check did not pass")


def audit_artifact(profile: str, report: dict[str, Any], errors: list[str]) -> None:
    target = step(report, "targetVerify")
    target_artifact = target.get("artifact") if isinstance(target.get("artifact"), dict) else {}
    client = step(report, "clientVerify")
    artifact = client.get("artifact") if isinstance(client.get("artifact"), dict) else {}
    expected_enabled = profile in {"storage", "builder"}
    if artifact.get("enabled") is not expected_enabled:
        errors.append(f"{profile}: client artifact enabled is {artifact.get('enabled')!r}, want {expected_enabled}")
    if target_artifact.get("enabled") is not expected_enabled:
        errors.append(f"{profile}: target artifact enabled is {target_artifact.get('enabled')!r}, want {expected_enabled}")
    if not expected_enabled:
        if artifact.get("catalogStatusCode") != 404:
            errors.append(f"{profile}: disabled artifact catalog status is {artifact.get('catalogStatusCode')!r}, want 404")
        if artifact.get("v2ChallengeStatusCode") not in (404, 503):
            errors.append(f"{profile}: disabled /v2/ status is {artifact.get('v2ChallengeStatusCode')!r}, want 404 or 503")
        return
    if target_artifact.get("readinessExitCode") != 0:
        errors.append(f"{profile}: zot pod/PVC readiness exit is {target_artifact.get('readinessExitCode')!r}, want 0")
    required = {
        "catalogStatusCode": lambda value: isinstance(value, int) and value < 400,
        "catalogFiltered": lambda value: value is True,
        "anonymousCatalogStatusCode": lambda value: value in (401, 403),
        "v2ChallengeStatusCode": lambda value: value == 401,
        "tokenIssuanceStatusCode": lambda value: isinstance(value, int) and value < 400,
        "deniedScopeStatusCode": lambda value: value in (200, 401, 403),
        "deniedScopeGranted": lambda value: value is False,
        "malformedTokenStatusCode": lambda value: value in (401, 403),
        "tokenRevokeStatusCode": lambda value: isinstance(value, int) and value < 300,
        "revokedCredentialStatusCode": lambda value: value in (401, 403),
        "revokedTokenChecked": lambda value: value is True,
    }
    for field, valid in required.items():
        if not valid(artifact.get(field)):
            errors.append(f"{profile}: artifact {field} evidence is invalid: {artifact.get(field)!r}")
    for field in ("ociSmoke", "orasSmoke", "offlineSmoke"):
        smoke = artifact.get(field)
        if isinstance(smoke, dict) and smoke.get("configured") is True and smoke.get("exitCode") != 0:
            errors.append(f"{profile}: configured {field} did not pass")


def build_summary(reports: dict[str, dict[str, Any]], errors: list[str]) -> dict[str, Any]:
    return {
        "status": "failed" if errors else "passed",
        "generatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "profiles": {
            profile: {
                "reportPath": report.get("_reportPath"),
                "markdownPath": report.get("_markdownPath"),
                "overallStatus": report.get("overallStatus"),
                "releaseVersion": report.get("releaseVersion"),
                "applianceProfile": report.get("applianceProfile"),
                "steps": step_statuses(report),
            }
            for profile, report in reports.items()
        },
        "errors": errors,
    }


def audit_plan(plan: dict[str, Any], reports: dict[str, dict[str, Any]], errors: list[str]) -> bool:
    if not plan:
        return False
    profiles = plan.get("profiles")
    if profiles != ["core", "storage", "builder"]:
        errors.append(f"plan profiles are {profiles!r}, want ['core', 'storage', 'builder']")
    expected_version = str(plan.get("releaseVersion") or "").strip()
    if expected_version:
        for profile, report in reports.items():
            actual = str(report.get("releaseVersion") or "").strip()
            if actual != expected_version:
                errors.append(f"{profile}: releaseVersion is {actual!r}, want plan releaseVersion {expected_version!r}")
    expected_paths = {
        "buildCatalogPath": normalized_path(plan.get("buildCatalogPath")),
    }
    for field, expected in expected_paths.items():
        if not expected:
            continue
        builder_report = reports.get("builder")
        if builder_report:
            actual = normalized_path(builder_report.get(field))
            if actual != expected:
                errors.append(f"builder: {field} is {actual!r}, want plan {field} {expected!r}")
        for profile, report in reports.items():
            if profile == "builder":
                continue
            actual = normalized_path(report.get(field))
            if actual and actual != expected:
                errors.append(f"{profile}: {field} is {actual!r}, want plan {field} {expected!r}")
    audit_command = plan.get("auditCommand") if isinstance(plan.get("auditCommand"), dict) else {}
    return bool(audit_command.get("requiresBuilderWorkflow"))


def write_summary(summary: dict[str, Any], output_path: str) -> None:
    if not output_path:
        return
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Audit release-report.json files from the core/storage/builder profile matrix.")
    parser.add_argument("--core-run-dir", required=True)
    parser.add_argument("--storage-run-dir", required=True)
    parser.add_argument("--builder-run-dir", required=True)
    parser.add_argument("--plan-json", help="Profile matrix plan JSON generated before the live runs.")
    parser.add_argument("--require-builder-workflow", action="store_true")
    parser.add_argument("--output-json")
    args = parser.parse_args()

    run_dirs = {
        "core": Path(args.core_run_dir),
        "storage": Path(args.storage_run_dir),
        "builder": Path(args.builder_run_dir),
    }

    errors: list[str] = []
    plan: dict[str, Any] = {}
    if args.plan_json:
        try:
            plan = read_plan(args.plan_json)
        except Exception as exc:
            errors.append(str(exc))
    reports: dict[str, dict[str, Any]] = {}
    for profile, path in run_dirs.items():
        try:
            reports[profile] = read_report(path)
        except Exception as exc:
            errors.append(f"{profile}: {exc}")
    versions = {str(report.get("releaseVersion") or "") for report in reports.values()}
    versions.discard("")
    if len(versions) > 1:
        errors.append(f"profile matrix reports have mismatched release versions: {sorted(versions)}")

    for profile, report in reports.items():
        audit_common(profile, report, errors)
        audit_artifact(profile, report, errors)
    plan_requires_workflow = audit_plan(plan, reports, errors)
    if "core" in reports:
        audit_non_builder("core", reports["core"], errors)
    if "storage" in reports:
        audit_non_builder("storage", reports["storage"], errors)
    if "builder" in reports:
        audit_builder(reports["builder"], bool(args.require_builder_workflow or plan_requires_workflow), errors)

    summary = build_summary(reports, errors)
    if plan:
        summary["planPath"] = plan.get("_planPath")
        summary["planReleaseVersion"] = plan.get("releaseVersion")
        summary["planRequiresBuilderWorkflow"] = plan_requires_workflow
    write_summary(summary, args.output_json or "")
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
