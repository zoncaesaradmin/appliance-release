#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
import sys


def parse_scalar(raw: str):
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in {"'", '"'}:
        return raw[1:-1]
    lowered = raw.lower()
    if lowered in {"true", "yes", "on"}:
        return True
    if lowered in {"false", "no", "off"}:
        return False
    if lowered in {"null", "~"}:
        return None
    if raw.isdigit():
        return int(raw)
    return raw


def parse_simple_yaml(text: str):
    lines = []
    for lineno, raw in enumerate(text.splitlines(), start=1):
        if not raw.strip():
            continue
        stripped = raw.lstrip(" ")
        if stripped.startswith("#"):
            continue
        indent = len(raw) - len(stripped)
        if "\t" in raw[:indent]:
            raise ValueError(f"tabs are not supported in YAML indentation (line {lineno})")
        if stripped.startswith("- "):
            raise ValueError(
                f"list syntax is not supported by this config reader; "
                f"use nested mappings instead (line {lineno})"
            )
        lines.append((lineno, indent, stripped))

    def parse_block(start: int, indent: int):
        obj = {}
        idx = start
        while idx < len(lines):
            lineno, current_indent, content = lines[idx]
            if current_indent < indent:
                break
            if current_indent > indent:
                raise ValueError(f"unexpected indentation at line {lineno}")
            if ":" not in content:
                raise ValueError(f"expected key: value syntax at line {lineno}")
            key, remainder = content.split(":", 1)
            key = key.strip()
            remainder = remainder.strip()
            idx += 1
            if remainder:
                obj[key] = parse_scalar(remainder)
                continue
            if idx < len(lines) and lines[idx][1] > current_indent:
                child_indent = lines[idx][1]
                obj[key], idx = parse_block(idx, child_indent)
            else:
                obj[key] = {}
        return obj, idx

    if not lines:
        return {}
    parsed, idx = parse_block(0, lines[0][1])
    if idx != len(lines):
        raise ValueError("failed to parse complete config")
    return parsed


def load_config(path: Path):
    text = path.read_text(encoding="utf-8")
    stripped = text.lstrip()
    if stripped.startswith("{") or stripped.startswith("["):
        return json.loads(text)
    return parse_simple_yaml(text)


def lookup(data, query: str):
    value = data
    for part in query.split("."):
        if not isinstance(value, dict) or part not in value:
            raise KeyError(query)
        value = value[part]
    return value


def main():
    parser = argparse.ArgumentParser(description="Read a nested value from a YAML or JSON config.")
    parser.add_argument("--keys", action="store_true", help="Print child keys of the selected mapping.")
    parser.add_argument("config_path")
    parser.add_argument("query")
    args = parser.parse_args()

    config = load_config(Path(args.config_path))
    value = lookup(config, args.query)

    if args.keys:
        if not isinstance(value, dict):
            raise SystemExit(f"{args.query} is not a mapping")
        for key in sorted(value.keys()):
            print(key)
        return

    if isinstance(value, dict):
        print(json.dumps(value, indent=2, sort_keys=True))
        return
    if value is None:
        print("")
        return
    if isinstance(value, bool):
        print("true" if value else "false")
        return
    print(value)


if __name__ == "__main__":
    try:
        main()
    except KeyError as exc:
        print(f"missing config key: {exc.args[0]}", file=sys.stderr)
        sys.exit(2)
    except Exception as exc:  # pragma: no cover - defensive cli path
        print(f"config query failed: {exc}", file=sys.stderr)
        sys.exit(1)
