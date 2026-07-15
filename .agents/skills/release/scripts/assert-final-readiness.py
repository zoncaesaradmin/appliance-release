#!/usr/bin/env python3
"""Fail unless the final readiness report proves the release objective."""

import argparse
import json
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description="Assert final appliance release readiness.")
    parser.add_argument("--readiness-json", required=True)
    args = parser.parse_args()

    path = Path(args.readiness_json).expanduser().resolve()
    if not path.is_file():
        print(f"final readiness report is missing: {path}")
        return 1
    with path.open("r", encoding="utf-8") as handle:
        report = json.load(handle)
    if not isinstance(report, dict):
        print(f"final readiness report must contain a JSON object: {path}")
        return 1
    if report.get("status") == "ready":
        print(f"final readiness is ready: {path}")
        return 0
    print(f"final readiness is {report.get('status')!r}, want 'ready': {path}")
    missing = report.get("missingEvidence")
    if isinstance(missing, list) and missing:
        print("missing evidence:")
        for item in missing:
            print(f"- {item}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
