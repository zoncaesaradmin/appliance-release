#!/usr/bin/env python3
"""Local tests for summarize-release-run.py."""

import json
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[4]
SUMMARIZER = ROOT / ".agents" / "skills" / "release" / "scripts" / "summarize-release-run.py"


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def test_complete_report() -> None:
    with tempfile.TemporaryDirectory(prefix="release-run-summary-") as tmp_dir:
        run_dir = Path(tmp_dir)
        metadata_dir = run_dir / "metadata"
        write_json(
            metadata_dir / "run-release-flow.json",
            {
                "configPath": "/tmp/config.yaml",
                "runDir": str(run_dir),
                "releaseVersion": "0.1.0",
                "applianceProfile": "builder",
                "status": "passed",
                "exitCode": 0,
                "buildCatalogPath": "/tmp/build-catalog.yaml",
                "sourceCredentialsPath": "/tmp/source-credentials.yaml",
                "steps": {
                    "buildPublishSkipped": False,
                    "installSkipped": False,
                    "bootstrapAdminSkipped": False,
                    "targetVerifySkipped": False,
                    "clientVerifySkipped": False,
                },
                "metadataFiles": {
                    "buildPublish": str(metadata_dir / "build-publish.json"),
                    "install": str(metadata_dir / "install.json"),
                    "targetVerify": str(metadata_dir / "verify.json"),
                    "clientVerify": str(metadata_dir / "client-verify.json"),
                },
            },
        )
        write_json(
            metadata_dir / "build-publish.json",
            {
                "releaseVersion": "0.1.0",
                "remoteReleaseCommit": "abc123",
                "artifactChecksums": [{"path": "bundle.tar.gz", "digest": "sha256:x"}],
                "releaseInputArtifacts": {"argoExecutorImage": {"digest": "sha256:y"}},
                "bundleEntries": [{"path": "oci-images/executor.tar", "digest": "sha256:z"}],
                "logs": {"releaseArtifactValidation": str(run_dir / "logs" / "release-artifact-validation.json")},
            },
        )
        write_json(
            metadata_dir / "install.json",
            {
                "targetHost": "target",
                "releaseVersion": "0.1.0",
                "applianceProfile": "builder",
                "bundleDir": "/tmp/appliance",
                "installMode": "upgrade",
                "log": str(run_dir / "logs" / "install.log"),
            },
        )
        write_json(
            metadata_dir / "verify.json",
            {
                "failed": False,
                "warnings": ["allowed ingress warning"],
                "checks": {"serviceHealth": {"exitCode": 0, "log": str(run_dir / "logs" / "service.log")}},
            },
        )
        write_json(
            metadata_dir / "client-verify.json",
            {
                "baseUrl": "https://target",
                "username": "admin",
                "checks": {
                    "login": {"statusCode": 200},
                    "builder": {
                        "workProfiles": {"statusCode": 200},
                        "mcpToolsList": {
                            "summary": {
                                "toolNames": ["list_work_profiles", "submit_build"],
                            }
                        },
                        "workflow": {
                            "jobId": "job-1",
                            "finalStatus": "succeeded",
                            "artifactRef": {
                                "submitBuild": "users/alice/app:v1",
                                "job": "users/alice/app:v1",
                                "matched": True,
                            },
                            "secretLeakCheck": {"passed": True},
                        },
                    },
                    "disabledBuildRoutes": {
                        "workProfiles": {"statusCode": 404},
                        "mcpToolsList": {"unexpectedToolNames": []},
                        "mcpDirectToolCall": {
                            "statusCode": 200,
                            "expectedJSONRPCError": {"code": -32601, "message": "Tool not found"},
                        },
                    },
                },
            },
        )

        result = subprocess.run(
            ["python3", str(SUMMARIZER), "--run-dir", str(run_dir)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0:
            raise AssertionError(result.stderr)
        report = json.loads((metadata_dir / "release-report.json").read_text(encoding="utf-8"))
        if report["overallStatus"] != "passed":
            raise AssertionError(report)
        if not str(report.get("generatedAt", "")).endswith("Z"):
            raise AssertionError(report)
        if report["steps"]["targetVerify"]["warningCount"] != 1:
            raise AssertionError(report)
        if report["steps"]["clientVerify"]["workflow"]["secretLeakCheckPassed"] is not True:
            raise AssertionError(report)
        if report["steps"]["clientVerify"]["workflow"]["artifactRef"] != "users/alice/app:v1":
            raise AssertionError(report)
        if "submit_build" not in report["steps"]["clientVerify"]["builderToolsPresent"]:
            raise AssertionError(report)
        if report["steps"]["clientVerify"]["builderWorkProfilesStatusCode"] != 200:
            raise AssertionError(report)
        if report["steps"]["clientVerify"]["disabledBuildWorkProfilesStatusCode"] != 404:
            raise AssertionError(report)
        direct = report["steps"]["clientVerify"]["disabledBuildDirectToolCall"]
        if direct["expectedJSONRPCError"]["message"] != "Tool not found":
            raise AssertionError(report)
        if not (run_dir / "release-report.md").is_file():
            raise AssertionError("missing markdown report")
        markdown = (run_dir / "release-report.md").read_text(encoding="utf-8")
        if "Generated at:" not in markdown:
            raise AssertionError(markdown)


def test_missing_unskipped_metadata_fails_summary_status() -> None:
    with tempfile.TemporaryDirectory(prefix="release-run-summary-") as tmp_dir:
        run_dir = Path(tmp_dir)
        metadata_dir = run_dir / "metadata"
        write_json(
            metadata_dir / "run-release-flow.json",
            {
                "runDir": str(run_dir),
                "releaseVersion": "0.1.0",
                "status": "passed",
                "exitCode": 0,
                "steps": {
                    "buildPublishSkipped": False,
                    "installSkipped": True,
                    "bootstrapAdminSkipped": True,
                    "targetVerifySkipped": False,
                    "clientVerifySkipped": True,
                },
                "metadataFiles": {
                    "buildPublish": str(metadata_dir / "build-publish.json"),
                },
            },
        )
        result = subprocess.run(
            ["python3", str(SUMMARIZER), "--run-dir", str(run_dir)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0:
            raise AssertionError(result.stderr)
        report = json.loads((metadata_dir / "release-report.json").read_text(encoding="utf-8"))
        if report["overallStatus"] != "failed":
            raise AssertionError(report)
        if report["steps"]["buildPublish"]["status"] != "missing":
            raise AssertionError(report)


def test_wrapper_failure_marks_report_failed() -> None:
    with tempfile.TemporaryDirectory(prefix="release-run-summary-") as tmp_dir:
        run_dir = Path(tmp_dir)
        metadata_dir = run_dir / "metadata"
        write_json(
            metadata_dir / "run-release-flow.json",
            {
                "runDir": str(run_dir),
                "releaseVersion": "0.1.0",
                "status": "failed",
                "exitCode": 42,
                "steps": {
                    "buildPublishSkipped": True,
                    "installSkipped": True,
                    "bootstrapAdminSkipped": True,
                    "targetVerifySkipped": False,
                    "clientVerifySkipped": True,
                },
                "metadataFiles": {},
            },
        )
        result = subprocess.run(
            ["python3", str(SUMMARIZER), "--run-dir", str(run_dir)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0:
            raise AssertionError(result.stderr)
        report = json.loads((metadata_dir / "release-report.json").read_text(encoding="utf-8"))
        if report["overallStatus"] != "failed":
            raise AssertionError(report)
        if report["wrapperExitCode"] != 42:
            raise AssertionError(report)


def main() -> None:
    test_complete_report()
    test_missing_unskipped_metadata_fails_summary_status()
    test_wrapper_failure_marks_report_failed()
    print("summarize-release-run tests passed")


if __name__ == "__main__":
    main()
