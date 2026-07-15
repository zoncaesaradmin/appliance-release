#!/usr/bin/env python3
"""Summarize whether final live release evidence is complete."""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
from typing import Any, Optional


def read_json(path: Path) -> Optional[dict[str, Any]]:
    if not path.is_file():
        return None
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return data


def evidence_file(path: Path) -> dict[str, Any]:
    return {
        "path": str(path),
        "exists": path.is_file(),
        "sizeBytes": path.stat().st_size if path.is_file() else None,
    }


def next_actions(missing: list[str]) -> list[str]:
    if not missing:
        return ["Run make assert-final-readiness as the final completion assertion."]
    actions: list[str] = []
    if "passing non-live local milestone report" in missing:
        actions.append("Run make verify-local-milestone.")
    if any(item.startswith("strict final profile matrix plan") for item in missing):
        actions.append("Run make final-profile-input-checklist to produce a non-failing checklist of missing builder catalog and workflow smoke inputs.")
        actions.append("Populate the final builder build catalog and workflow smoke config, then run make plan-final-profile-matrix.")
    if any(item.startswith("strict final profile matrix audit") or item.startswith("passing strict final profile matrix audit") for item in missing):
        actions.append("Run the real core/storage/builder profile-matrix commands from final-profile-matrix-plan.md, then run make audit-final-profile-matrix.")
    actions.append("Run make assert-final-readiness after final plan and final audit evidence exist.")
    return actions


def checklist_summary(checklist: Optional[dict[str, Any]]) -> dict[str, Any]:
    if checklist is None:
        return {
            "status": "missing",
            "readyForFinalPlan": False,
            "validationErrors": [],
        }
    errors = checklist.get("validationErrors")
    if not isinstance(errors, list):
        errors = []
    ready = checklist.get("readyForFinalPlan") is True and not errors
    return {
        "status": "passed" if ready else "incomplete",
        "readyForFinalPlan": ready,
        "validationErrors": [str(error) for error in errors],
        "checklistOnly": checklist.get("checklistOnly") is True,
        "generatedAt": checklist.get("generatedAt"),
    }


def write_markdown(path: Path, report: dict[str, Any]) -> None:
    lines = [
        "# Final Readiness Report",
        "",
        f"- Status: `{report.get('status')}`",
        f"- Generated at: `{report.get('generatedAt')}`",
        f"- Local milestone status: `{report.get('localMilestoneStatus')}`",
        f"- Final input checklist status: `{report.get('finalInputChecklistStatus')}`",
        f"- Final plan status: `{report.get('finalPlanStatus')}`",
        f"- Final audit status: `{report.get('finalAuditStatus')}`",
        "",
        "## Missing Evidence",
        "",
    ]
    missing = report.get("missingEvidence") or []
    if missing:
        lines.extend(f"- {item}" for item in missing)
    else:
        lines.append("- None")
    checklist = report.get("finalInputChecklist") if isinstance(report.get("finalInputChecklist"), dict) else {}
    checklist_errors = checklist.get("validationErrors") if isinstance(checklist.get("validationErrors"), list) else []
    if checklist_errors:
        lines.extend(["", "## Final Input Checklist", ""])
        lines.append(f"- Ready for final plan: `{str(checklist.get('readyForFinalPlan')).lower()}`")
        lines.append(f"- Validation error count: `{len(checklist_errors)}`")
        lines.extend(f"- {item}" for item in checklist_errors)
    lines.extend(["", "## Next Actions", ""])
    for item in report.get("nextActions") or []:
        lines.append(f"- {item}")
    lines.extend(["", "## Evidence Files", ""])
    for name, info in (report.get("evidenceFiles") or {}).items():
        lines.append(f"- `{name}`: exists `{str(info.get('exists')).lower()}` at `{info.get('path')}`")
    lines.append("")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Write final appliance release readiness evidence.")
    parser.add_argument("--local-milestone-json", required=True)
    parser.add_argument("--final-input-checklist-json")
    parser.add_argument("--final-plan-json", required=True)
    parser.add_argument("--final-audit-json", required=True)
    parser.add_argument("--output-json", required=True)
    parser.add_argument("--output-md")
    args = parser.parse_args()

    local_path = Path(args.local_milestone_json).expanduser().resolve()
    checklist_path = Path(args.final_input_checklist_json).expanduser().resolve() if args.final_input_checklist_json else None
    plan_path = Path(args.final_plan_json).expanduser().resolve()
    audit_path = Path(args.final_audit_json).expanduser().resolve()
    output = Path(args.output_json).expanduser().resolve()

    local = read_json(local_path)
    checklist = read_json(checklist_path) if checklist_path is not None else None
    final_input_checklist = checklist_summary(checklist)
    plan = read_json(plan_path)
    audit = read_json(audit_path)
    missing: list[str] = []

    local_status = str((local or {}).get("status") or "missing")
    if local_status != "passed":
        missing.append("passing non-live local milestone report")

    plan_errors = (plan or {}).get("validationErrors")
    final_plan_status = "missing"
    if plan is not None:
        final_plan_status = "passed" if plan_errors == [] else "failed"
    if plan is None:
        missing.append("strict final profile matrix plan")
    elif plan_errors:
        missing.append("strict final profile matrix plan without validation errors")
    elif not ((plan.get("auditCommand") or {}).get("requiresBuilderWorkflow") is True):
        final_plan_status = "failed"
        missing.append("strict final profile matrix plan requiring builder workflow evidence")

    final_audit_status = str((audit or {}).get("status") or "missing")
    if audit is None:
        missing.append("strict final profile matrix audit")
    elif final_audit_status != "passed":
        missing.append("passing strict final profile matrix audit")
    elif audit.get("planRequiresBuilderWorkflow") is not True:
        final_audit_status = "failed"
        missing.append("strict final profile matrix audit requiring builder workflow evidence")

    report = {
        "status": "ready" if not missing else "not_ready",
        "generatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "localMilestoneStatus": local_status,
        "finalInputChecklist": final_input_checklist,
        "finalInputChecklistStatus": final_input_checklist["status"],
        "finalPlanStatus": final_plan_status,
        "finalAuditStatus": final_audit_status,
        "missingEvidence": missing,
        "nextActions": next_actions(missing),
        "evidenceFiles": {
            "localMilestone": evidence_file(local_path),
            "finalInputChecklist": evidence_file(checklist_path) if checklist_path is not None else {"path": None, "exists": False, "sizeBytes": None},
            "finalPlan": evidence_file(plan_path),
            "finalAudit": evidence_file(audit_path),
        },
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    result = {"finalReadinessReport": str(output)}
    if args.output_md:
        md_output = Path(args.output_md).expanduser().resolve()
        write_markdown(md_output, report)
        result["finalReadinessReportMarkdown"] = str(md_output)
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
