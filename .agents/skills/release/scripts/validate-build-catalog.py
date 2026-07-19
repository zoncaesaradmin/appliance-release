#!/usr/bin/env python3
"""Validate builder build-catalog inputs for the normal release flow."""

import argparse
import importlib.util
import json
from pathlib import Path
import sys


SCRIPT_DIR = Path(__file__).resolve().parent
PLAN_SCRIPT = SCRIPT_DIR / "plan-profile-matrix.py"


def load_plan_module():
    spec = importlib.util.spec_from_file_location("plan_profile_matrix", PLAN_SCRIPT)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {PLAN_SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate a builder build catalog against release config inputs.")
    parser.add_argument("--config", required=True)
    parser.add_argument("--build-catalog", required=True)
    parser.add_argument("--output-json")
    args = parser.parse_args()

    plan = load_plan_module()
    config_path = Path(args.config).expanduser().resolve()
    build_catalog = args.build_catalog
    config = plan.load_config(config_path)

    errors = []
    file_error = plan.file_error(config_path, build_catalog, "install.build_catalog_path")
    if file_error:
        errors.append(file_error)
    else:
        errors.extend(plan.validate_build_catalog(config_path, config, build_catalog))

    payload = {
        "configPath": str(config_path),
        "buildCatalogPath": str(plan.resolve_config_relative_path(config_path, build_catalog).resolve()),
        "valid": not bool(errors),
        "validationErrors": errors,
    }
    if args.output_json:
        out = Path(args.output_json).expanduser().resolve()
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
