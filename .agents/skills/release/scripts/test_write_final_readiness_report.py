#!/usr/bin/env python3
"""Local tests for write-final-readiness-report.py."""

import json
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[4]
WRITER = ROOT / ".agents" / "skills" / "release" / "scripts" / "write-final-readiness-report.py"


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def run_writer(root: Path, *, checklist: bool = False, final_plan: bool = False, final_audit: bool = False) -> dict:
    local = root / "local-milestone-report.json"
    checklist_path = root / "final-profile-input-checklist.json"
    plan = root / "final-profile-matrix-plan.json"
    audit = root / "final-profile-matrix-audit.json"
    output = root / "final-readiness-report.json"
    output_md = root / "final-readiness-report.md"
    write_json(local, {"status": "passed"})
    if checklist:
        write_json(
            checklist_path,
            {
                "checklistOnly": True,
                "readyForFinalPlan": False,
                "validationErrors": [
                    "client_verification.builder.workflow.enabled must be true for final builder workflow evidence",
                    "install.build_catalog_path is required for final builder workflow evidence",
                ],
            },
        )
    if final_plan:
        write_json(
            plan,
            {
                "validationErrors": [],
                "auditCommand": {"requiresBuilderWorkflow": True},
            },
        )
    if final_audit:
        write_json(audit, {"status": "passed", "planRequiresBuilderWorkflow": True})
    result = subprocess.run(
        [
            "python3",
            str(WRITER),
            "--local-milestone-json",
            str(local),
            "--final-input-checklist-json",
            str(checklist_path),
            "--final-plan-json",
            str(plan),
            "--final-audit-json",
            str(audit),
            "--output-json",
            str(output),
            "--output-md",
            str(output_md),
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise AssertionError(result.stderr)
    report = json.loads(output.read_text(encoding="utf-8"))
    markdown = output_md.read_text(encoding="utf-8")
    if not str(report.get("generatedAt", "")).endswith("Z"):
        raise AssertionError(report)
    if "Generated at:" not in markdown:
        raise AssertionError(markdown)
    if "## Missing Evidence" not in markdown or "## Next Actions" not in markdown:
        raise AssertionError(markdown)
    if checklist and "## Final Input Checklist" not in markdown:
        raise AssertionError(markdown)
    return report


def test_not_ready_without_live_evidence() -> None:
    with tempfile.TemporaryDirectory(prefix="final-readiness-") as tmp_dir:
        report = run_writer(Path(tmp_dir))
        if report["status"] != "not_ready":
            raise AssertionError(report)
        if "strict final profile matrix plan" not in report["missingEvidence"]:
            raise AssertionError(report)
        if "strict final profile matrix audit" not in report["missingEvidence"]:
            raise AssertionError(report)
        actions = "\n".join(report.get("nextActions") or [])
        if "make final-profile-input-checklist" not in actions:
            raise AssertionError(report)
        if "make plan-final-profile-matrix" not in actions:
            raise AssertionError(report)
        if "make audit-final-profile-matrix" not in actions:
            raise AssertionError(report)
        if report["finalInputChecklistStatus"] != "missing":
            raise AssertionError(report)


def test_not_ready_surfaces_final_input_checklist_errors() -> None:
    with tempfile.TemporaryDirectory(prefix="final-readiness-") as tmp_dir:
        report = run_writer(Path(tmp_dir), checklist=True)
        if report["status"] != "not_ready":
            raise AssertionError(report)
        if report["finalInputChecklistStatus"] != "incomplete":
            raise AssertionError(report)
        checklist = report.get("finalInputChecklist") or {}
        if checklist.get("readyForFinalPlan") is not False:
            raise AssertionError(report)
        errors = "\n".join(checklist.get("validationErrors") or [])
        if "install.build_catalog_path" not in errors:
            raise AssertionError(report)


def test_ready_with_all_evidence() -> None:
    with tempfile.TemporaryDirectory(prefix="final-readiness-") as tmp_dir:
        report = run_writer(Path(tmp_dir), final_plan=True, final_audit=True)
        if report["status"] != "ready":
            raise AssertionError(report)
        if report["missingEvidence"]:
            raise AssertionError(report)
        if "make assert-final-readiness" not in "\n".join(report.get("nextActions") or []):
            raise AssertionError(report)


def main() -> None:
    test_not_ready_without_live_evidence()
    test_not_ready_surfaces_final_input_checklist_errors()
    test_ready_with_all_evidence()
    print("write-final-readiness-report tests passed")


if __name__ == "__main__":
    main()
