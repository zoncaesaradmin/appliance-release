#!/usr/bin/env python3
"""Local tests for write-local-milestone-report.py."""

import json
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[4]
WRITER = ROOT / ".agents" / "skills" / "release" / "scripts" / "write-local-milestone-report.py"


def test_writes_non_live_report() -> None:
    with tempfile.TemporaryDirectory(prefix="local-milestone-report-") as tmp_dir:
        root = Path(tmp_dir)
        log_dir = root / "logs"
        log_dir.mkdir()
        for name in (
            "verify-local-milestone-appliance-release.log",
            "verify-local-milestone-appliance-code-controlplane.log",
            "verify-local-milestone-appliance-code-chart.log",
            "verify-local-milestone-appliance-code-ui.log",
            "verify-local-milestone-appliance-code-e2e.log",
            "verify-local-milestone-appliance-ctl.log",
        ):
            (log_dir / name).write_text("ok\n", encoding="utf-8")
        output = root / "appliance-release" / ".run" / "appliance-release" / "local-milestone-report.json"
        output_md = root / "appliance-release" / ".run" / "appliance-release" / "local-milestone-report.md"
        result = subprocess.run(
            [
                "python3",
                str(WRITER),
                "--output-json",
                str(output),
                "--output-md",
                str(output_md),
                "--appliance-code-dir",
                str(root / "appliance-code"),
                "--appliance-ctl-dir",
                str(root / "appliance-ctl"),
                "--release-log-dir",
                str(log_dir),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0:
            raise AssertionError(result.stderr)
        report = json.loads(output.read_text(encoding="utf-8"))
        if report["status"] != "passed":
            raise AssertionError(report)
        if not str(report.get("generatedAt", "")).endswith("Z"):
            raise AssertionError(report)
        if report["usesRealTargetHost"] is not False:
            raise AssertionError(report)
        if len(report["gates"]) != 6:
            raise AssertionError(report)
        if set(report["repositories"]) != {"applianceRelease", "applianceCode", "applianceCtl"}:
            raise AssertionError(report)
        if report["repositories"]["applianceRelease"]["isGitRepository"] is not False:
            raise AssertionError(report)
        if not all(log["exists"] for gate in report["gates"] for log in gate["logs"]):
            raise AssertionError(report)
        if "real core/storage/builder profile-matrix runs" not in report["remainingLiveEvidence"]:
            raise AssertionError(report)
        markdown = output_md.read_text(encoding="utf-8")
        if "Generated at:" not in markdown:
            raise AssertionError(markdown)
        if "## Repository Provenance" not in markdown or "## Remaining Live Evidence" not in markdown:
            raise AssertionError(markdown)
        if "real builder workflow smoke" not in markdown:
            raise AssertionError(markdown)


def main() -> None:
    test_writes_non_live_report()
    print("write-local-milestone-report tests passed")


if __name__ == "__main__":
    main()
