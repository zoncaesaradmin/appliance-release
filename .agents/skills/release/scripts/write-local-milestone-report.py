#!/usr/bin/env python3
"""Write a durable summary for the non-live cross-repo milestone gate."""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
from typing import Any


def log_info(path: Path) -> dict[str, Any]:
    exists = path.is_file()
    return {
        "path": str(path),
        "exists": exists,
        "sizeBytes": path.stat().st_size if exists else None,
    }


def git_output(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        return ""
    return result.stdout.strip()


def repo_info(repo: Path) -> dict[str, Any]:
    repo = repo.expanduser().resolve()
    top_level = git_output(repo, "rev-parse", "--show-toplevel")
    if not top_level:
        return {
            "path": str(repo),
            "isGitRepository": False,
        }
    status_lines = git_output(repo, "status", "--short").splitlines()
    return {
        "path": str(repo),
        "topLevel": top_level,
        "isGitRepository": True,
        "branch": git_output(repo, "rev-parse", "--abbrev-ref", "HEAD") or None,
        "head": git_output(repo, "rev-parse", "HEAD") or None,
        "dirty": bool(status_lines),
        "statusLineCount": len(status_lines),
    }


def write_markdown(path: Path, report: dict[str, Any]) -> None:
    lines = [
        "# Local Milestone Verification Report",
        "",
        f"- Status: `{report.get('status')}`",
        f"- Generated at: `{report.get('generatedAt')}`",
        f"- Scope: `{report.get('scope')}`",
        f"- Uses real build server: `{str(report.get('usesRealBuildServer')).lower()}`",
        f"- Uses real publish server: `{str(report.get('usesRealPublishServer')).lower()}`",
        f"- Uses real target host: `{str(report.get('usesRealTargetHost')).lower()}`",
        "",
        "## Repository Provenance",
        "",
    ]
    for name, repo in (report.get("repositories") or {}).items():
        if not repo.get("isGitRepository"):
            lines.append(f"- `{name}`: not a git repository at `{repo.get('path')}`")
            continue
        head = str(repo.get("head") or "")
        short_head = head[:12] if head else "unknown"
        lines.append(
            f"- `{name}`: branch `{repo.get('branch')}`, HEAD `{short_head}`, "
            f"dirty `{str(repo.get('dirty')).lower()}`, status lines `{repo.get('statusLineCount')}`"
        )
    lines.extend(["", "## Gates", ""])
    for gate in report.get("gates") or []:
        log_paths = ", ".join(f"`{log.get('path')}`" for log in gate.get("logs") or [])
        lines.append(f"- `{gate.get('name')}`: `{gate.get('command')}` in `{gate.get('cwd')}`; logs: {log_paths}")
    lines.extend(["", "## Remaining Live Evidence", ""])
    for item in report.get("remainingLiveEvidence") or []:
        lines.append(f"- {item}")
    lines.append("")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Write local milestone verification evidence.")
    parser.add_argument("--output-json", required=True)
    parser.add_argument("--output-md")
    parser.add_argument("--appliance-code-dir", required=True)
    parser.add_argument("--appliance-ctl-dir", required=True)
    parser.add_argument("--release-log-dir", required=True)
    args = parser.parse_args()

    output = Path(args.output_json).expanduser().resolve()
    log_dir = Path(args.release_log_dir).expanduser().resolve()
    appliance_release_dir = output.parents[2]
    appliance_code_dir = Path(args.appliance_code_dir).expanduser().resolve()
    appliance_ctl_dir = Path(args.appliance_ctl_dir).expanduser().resolve()
    gates = [
        {
            "name": "appliance-release",
            "command": "make verify",
            "cwd": str(appliance_release_dir),
            "logs": [log_info(log_dir / "verify-local-milestone-appliance-release.log")],
        },
        {
            "name": "appliance-code controlplane",
            "command": "go test ./...",
            "cwd": str(appliance_code_dir / "services" / "controlplane"),
            "logs": [log_info(log_dir / "verify-local-milestone-appliance-code-controlplane.log")],
        },
        {
            "name": "appliance-code control-plane chart",
            "command": "go test ./...",
            "cwd": str(appliance_code_dir / "deploy" / "charts" / "appliance-control-plane"),
            "logs": [log_info(log_dir / "verify-local-milestone-appliance-code-chart.log")],
        },
        {
            "name": "appliance-code UI",
            "command": "go test ./...",
            "cwd": str(appliance_code_dir / "services" / "ui"),
            "logs": [log_info(log_dir / "verify-local-milestone-appliance-code-ui.log")],
        },
        {
            "name": "appliance-code local e2e",
            "command": "make test-local",
            "cwd": str(appliance_code_dir / "e2etests"),
            "logs": [log_info(log_dir / "verify-local-milestone-appliance-code-e2e.log")],
        },
        {
            "name": "appliance-ctl",
            "command": "go test ./...",
            "cwd": str(appliance_ctl_dir),
            "logs": [log_info(log_dir / "verify-local-milestone-appliance-ctl.log")],
        },
    ]
    report = {
        "status": "passed",
        "generatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "scope": "non-live local milestone verification",
        "usesRealBuildServer": False,
        "usesRealPublishServer": False,
        "usesRealTargetHost": False,
        "applianceCodeDir": str(appliance_code_dir),
        "applianceCtlDir": str(appliance_ctl_dir),
        "repositories": {
            "applianceRelease": repo_info(appliance_release_dir),
            "applianceCode": repo_info(appliance_code_dir),
            "applianceCtl": repo_info(appliance_ctl_dir),
        },
        "gates": gates,
        "remainingLiveEvidence": [
            "real core/storage/builder profile-matrix runs",
            "real builder workflow smoke with product builder image, source credentials, Git reachability, and registry readiness",
            "audit of generated live release reports",
        ],
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    result = {"localMilestoneReport": str(output)}
    if args.output_md:
        md_output = Path(args.output_md).expanduser().resolve()
        write_markdown(md_output, report)
        result["localMilestoneReportMarkdown"] = str(md_output)
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
