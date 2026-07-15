#!/usr/bin/env python3
"""Local tests for assert-final-readiness.py."""

import json
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[4]
ASSERT = ROOT / ".agents" / "skills" / "release" / "scripts" / "assert-final-readiness.py"


def run_assert(path: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["python3", str(ASSERT), "--readiness-json", str(path)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def test_missing_report_fails() -> None:
    with tempfile.TemporaryDirectory(prefix="assert-final-readiness-") as tmp_dir:
        result = run_assert(Path(tmp_dir) / "missing.json")
        if result.returncode == 0:
            raise AssertionError("missing readiness report was accepted")
        if "missing" not in result.stdout:
            raise AssertionError(result.stdout)


def test_not_ready_report_fails_with_missing_evidence() -> None:
    with tempfile.TemporaryDirectory(prefix="assert-final-readiness-") as tmp_dir:
        path = Path(tmp_dir) / "readiness.json"
        write_json(path, {"status": "not_ready", "missingEvidence": ["strict final profile matrix audit"]})
        result = run_assert(path)
        if result.returncode == 0:
            raise AssertionError("not_ready report was accepted")
        if "strict final profile matrix audit" not in result.stdout:
            raise AssertionError(result.stdout)


def test_ready_report_passes() -> None:
    with tempfile.TemporaryDirectory(prefix="assert-final-readiness-") as tmp_dir:
        path = Path(tmp_dir) / "readiness.json"
        write_json(path, {"status": "ready", "missingEvidence": []})
        result = run_assert(path)
        if result.returncode != 0:
            raise AssertionError(result.stdout + result.stderr)


def main() -> None:
    test_missing_report_fails()
    test_not_ready_report_fails_with_missing_evidence()
    test_ready_report_passes()
    print("assert-final-readiness tests passed")


if __name__ == "__main__":
    main()
