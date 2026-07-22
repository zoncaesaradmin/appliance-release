#!/usr/bin/env python3
"""Aggregate appliance release run metadata into a concise final report."""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import sys
from typing import Any, Optional


def read_json(path: Path) -> Optional[dict]:
    if not path.is_file():
        return None
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return data


def rel(path: Optional[str], run_dir: Path) -> Optional[str]:
    if not path:
        return None
    try:
        return str(Path(path).resolve().relative_to(run_dir.resolve()))
    except ValueError:
        return path


def status_code_ok(check: dict) -> bool:
    code = check.get("statusCode")
    return isinstance(code, int) and code < 400


def step_status(skipped: bool, metadata: Optional[dict], failed: Optional[bool] = None) -> str:
    if skipped:
        return "skipped"
    if metadata is None:
        return "missing"
    if failed is True:
        return "failed"
    return "passed"


def summarize_build(build: Optional[dict], run_dir: Path, skipped: bool) -> dict:
    out = {"status": step_status(skipped, build)}
    if not build:
        return out
    out.update(
        {
            "releaseVersion": build.get("releaseVersion"),
            "remoteReleaseCommit": build.get("remoteReleaseCommit"),
            "artifactChecksumCount": len(build.get("artifactChecksums") or []),
            "releaseInputArtifactKeys": sorted((build.get("releaseInputArtifacts") or {}).keys()),
            "bundleEntryCount": len(build.get("bundleEntries") or []),
            "logs": {key: rel(value, run_dir) for key, value in (build.get("logs") or {}).items()},
        }
    )
    return out


def summarize_install(install: Optional[dict], run_dir: Path, skipped: bool) -> dict:
    out = {"status": step_status(skipped, install)}
    if not install:
        return out
    out.update(
        {
            "targetHost": install.get("targetHost"),
            "releaseVersion": install.get("releaseVersion"),
            "applianceProfile": install.get("applianceProfile"),
            "bundleDir": install.get("bundleDir"),
            "installMode": install.get("installMode"),
            "log": rel(install.get("log"), run_dir),
        }
    )
    return out


def summarize_target_verify(verify: Optional[dict], run_dir: Path, skipped: bool) -> dict:
    failed = verify.get("failed") if verify else None
    out = {"status": step_status(skipped, verify, failed if isinstance(failed, bool) else None)}
    if not verify:
        return out
    checks = verify.get("checks") if isinstance(verify.get("checks"), dict) else {}
    artifact = checks.get("artifact") if isinstance(checks.get("artifact"), dict) else {}
    out.update(
        {
            "failed": verify.get("failed"),
            "warningCount": len(verify.get("warnings") or []),
            "warnings": verify.get("warnings") or [],
            "checkStatuses": {
                name: {
                    "exitCode": check.get("exitCode"),
                    "log": rel(check.get("log"), run_dir),
                }
                for name, check in checks.items()
                if isinstance(check, dict)
            },
            "artifact": {
                "enabled": artifact.get("enabled"),
                "readinessExitCode": (artifact.get("readiness") or {}).get("exitCode"),
            },
        }
    )
    return out


def summarize_client_verify(client: Optional[dict], run_dir: Path, skipped: bool) -> dict:
    out = {"status": step_status(skipped, client)}
    if not client:
        return out
    checks = client.get("checks") if isinstance(client.get("checks"), dict) else {}
    builder = checks.get("builder") if isinstance(checks.get("builder"), dict) else None
    disabled = checks.get("disabledBuildRoutes") if isinstance(checks.get("disabledBuildRoutes"), dict) else None
    workflow = builder.get("workflow") if isinstance(builder, dict) and isinstance(builder.get("workflow"), dict) else None
    artifact = checks.get("artifact") if isinstance(checks.get("artifact"), dict) else {}
    out.update(
        {
            "baseUrl": client.get("baseUrl"),
            "username": client.get("username"),
            "loginStatusCode": (checks.get("login") or {}).get("statusCode") if isinstance(checks.get("login"), dict) else None,
            "builderWorkProfilesStatusCode": ((builder or {}).get("workProfiles") or {}).get("statusCode")
            if builder
            else None,
            "builderToolsPresent": sorted(
                ((builder or {}).get("mcpToolsList") or {}).get("summary", {}).get("toolNames", [])
            )
            if builder
            else [],
            "disabledBuildWorkProfilesStatusCode": ((disabled or {}).get("workProfiles") or {}).get("statusCode")
            if disabled
            else None,
            "disabledBuildUnexpectedTools": ((disabled or {}).get("mcpToolsList") or {}).get(
                "unexpectedToolNames", []
            )
            if disabled
            else [],
            "disabledBuildDirectToolCall": {
                "statusCode": ((disabled or {}).get("mcpDirectToolCall") or {}).get("statusCode"),
                "expectedJSONRPCError": ((disabled or {}).get("mcpDirectToolCall") or {}).get(
                    "expectedJSONRPCError"
                ),
            }
            if disabled
            else None,
            "workflow": {
                "enabled": workflow is not None,
                "jobId": workflow.get("jobId") if workflow else None,
                "finalStatus": workflow.get("finalStatus") if workflow else None,
                "artifactRef": ((workflow.get("artifactRef") or {}).get("job") if workflow else None),
                "secretLeakCheckPassed": (workflow.get("secretLeakCheck") or {}).get("passed")
                if workflow
                else None,
            },
            "artifact": {
                "enabled": artifact.get("enabled"),
                "catalogStatusCode": artifact.get("catalogStatusCode"),
                "catalogFiltered": artifact.get("catalogFiltered"),
                "anonymousCatalogStatusCode": artifact.get("anonymousCatalogStatusCode"),
                "v2ChallengeStatusCode": artifact.get("v2ChallengeStatusCode"),
                "tokenIssuanceStatusCode": artifact.get("tokenIssuanceStatusCode"),
                "deniedScopeStatusCode": artifact.get("deniedScopeStatusCode"),
                "malformedTokenStatusCode": artifact.get("malformedTokenStatusCode"),
                "tokenRevokeStatusCode": artifact.get("tokenRevokeStatusCode"),
                "revokedCredentialStatusCode": artifact.get("revokedCredentialStatusCode"),
                "revokedTokenChecked": artifact.get("revokedTokenChecked"),
                "ociSmoke": artifact.get("ociSmoke"),
                "orasSmoke": artifact.get("orasSmoke"),
                "offlineSmoke": artifact.get("offlineSmoke"),
            },
        }
    )
    return out


def write_markdown(path: Path, report: dict) -> None:
    lines = [
        "# Appliance Release Report",
        "",
        f"- Run directory: `{report.get('runDir')}`",
        f"- Generated at: `{report.get('generatedAt')}`",
        f"- Release version: `{report.get('releaseVersion') or 'unknown'}`",
        f"- Appliance profile: `{report.get('applianceProfile') or 'default/core'}`",
        f"- Overall status: `{report.get('overallStatus')}`",
        "",
        "## Steps",
    ]
    for name, step in (report.get("steps") or {}).items():
        lines.append(f"- `{name}`: `{step.get('status')}`")
    warnings = (report.get("steps", {}).get("targetVerify") or {}).get("warnings") or []
    if warnings:
        lines.extend(["", "## Warnings"])
        for warning in warnings:
            lines.append(f"- {warning}")
    lines.append("")
    path.write_text("\n".join(lines), encoding="utf-8")


def load_metadata(run_dir: Path, flow: dict, key: str) -> Optional[dict]:
    metadata_files = flow.get("metadataFiles") if isinstance(flow.get("metadataFiles"), dict) else {}
    path = metadata_files.get(key)
    if not isinstance(path, str) or not path:
        return None
    return read_json(Path(path))


def main() -> int:
    parser = argparse.ArgumentParser(description="Summarize an appliance release run.")
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--output-json")
    parser.add_argument("--output-md")
    args = parser.parse_args()

    run_dir = Path(args.run_dir)
    flow_path = run_dir / "metadata" / "run-release-flow.json"
    flow = read_json(flow_path)
    if flow is None:
        raise ValueError(f"missing release flow metadata: {flow_path}")

    steps = flow.get("steps") if isinstance(flow.get("steps"), dict) else {}
    build = load_metadata(run_dir, flow, "buildPublish")
    install = load_metadata(run_dir, flow, "install")
    target_verify = load_metadata(run_dir, flow, "targetVerify")
    client_verify = load_metadata(run_dir, flow, "clientVerify")
    report = {
        "configPath": flow.get("configPath"),
        "generatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "runDir": str(run_dir),
        "releaseVersion": flow.get("releaseVersion"),
        "applianceProfile": flow.get("applianceProfile"),
        "buildCatalogPath": flow.get("buildCatalogPath"),
        "wrapperStatus": flow.get("status"),
        "wrapperExitCode": flow.get("exitCode"),
        "steps": {
            "buildPublish": summarize_build(build, run_dir, bool(steps.get("buildPublishSkipped"))),
            "install": summarize_install(install, run_dir, bool(steps.get("installSkipped"))),
            "targetVerify": summarize_target_verify(
                target_verify, run_dir, bool(steps.get("targetVerifySkipped"))
            ),
            "clientVerify": summarize_client_verify(
                client_verify, run_dir, bool(steps.get("clientVerifySkipped"))
            ),
        },
    }
    statuses = [step.get("status") for step in report["steps"].values()]
    wrapper_failed = report.get("wrapperExitCode") not in (None, 0) or report.get("wrapperStatus") == "failed"
    report["overallStatus"] = (
        "failed"
        if wrapper_failed or any(status in {"failed", "missing"} for status in statuses)
        else "passed"
    )

    out_json = Path(args.output_json) if args.output_json else run_dir / "metadata" / "release-report.json"
    out_md = Path(args.output_md) if args.output_md else run_dir / "release-report.md"
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_md.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    write_markdown(out_md, report)
    print(json.dumps({"reportJson": str(out_json), "reportMarkdown": str(out_md)}, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"summarize-release-run: {exc}", file=sys.stderr)
        raise SystemExit(1)
