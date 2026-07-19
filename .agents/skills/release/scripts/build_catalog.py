#!/usr/bin/env python3
"""Helpers for reading the appliance builder build catalog without PyYAML."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Optional


def parse_scalar(raw: str) -> Any:
    raw = raw.strip()
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


def load_build_catalog(path: Path) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8", errors="replace")
    stripped = text.lstrip()
    if stripped.startswith("{") or stripped.startswith("["):
        data = json.loads(text)
        if not isinstance(data, dict):
            raise ValueError("build catalog must contain a JSON object")
        return data
    return parse_simple_list_manifest(text)


def parse_simple_list_manifest(text: str) -> dict[str, Any]:
    data: dict[str, Any] = {}
    current_key = ""
    current_item: Optional[dict[str, Any]] = None
    nested_item: Optional[dict[str, Any]] = None

    def flush_nested_item() -> None:
        nonlocal nested_item
        if current_item is None or nested_item is None:
            return
        pending_lists = current_item.get("__pending_lists__")
        if not isinstance(pending_lists, dict):
            nested_item = None
            return
        pending_key = str(pending_lists.get("key") or "").strip()
        if pending_key:
            current_item.setdefault(pending_key, []).append(nested_item)
        nested_item = None

    def flush_current_item() -> None:
        nonlocal current_item
        if current_item is None or not current_key:
            return
        flush_nested_item()
        current_item.pop("__pending_lists__", None)
        data.setdefault(current_key, []).append(current_item)
        current_item = None

    for raw in text.splitlines():
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        stripped_line = line.lstrip(" ")
        indent = len(line) - len(stripped_line)
        if indent == 0:
            if ":" not in stripped_line:
                raise ValueError("expected top-level key: value")
            flush_current_item()
            key, value = stripped_line.split(":", 1)
            current_key = key.strip()
            value = value.strip()
            if value:
                data[current_key] = parse_scalar(value)
            else:
                data.setdefault(current_key, [])
            continue
        if not current_key:
            continue
        if stripped_line.startswith("- "):
            remainder = stripped_line[2:].strip()
            pending_lists = current_item.get("__pending_lists__") if current_item is not None else None
            pending_key = str(pending_lists.get("key") or "").strip() if isinstance(pending_lists, dict) else ""
            if pending_key and indent > 2:
                flush_nested_item()
                if remainder and ":" in remainder:
                    nested_item = {}
                    key, value = remainder.split(":", 1)
                    nested_item[key.strip()] = parse_scalar(value)
                    continue
                if remainder:
                    current_item.setdefault(pending_key, []).append(parse_scalar(remainder))
                    continue
            flush_current_item()
            current_item = {}
            if remainder:
                if ":" not in remainder:
                    raise ValueError("expected key: value after '-'")
                key, value = remainder.split(":", 1)
                current_item[key.strip()] = parse_scalar(value)
            continue
        if current_item is None:
            continue
        if nested_item is not None:
            if ":" not in stripped_line:
                raise ValueError("expected key: value in nested list entry")
            key, value = stripped_line.split(":", 1)
            key = key.strip()
            value = value.strip()
            nested_item[key] = parse_scalar(value) if value else []
            continue
        if ":" not in stripped_line:
            raise ValueError("expected key: value in list entry")
        key, value = stripped_line.split(":", 1)
        key = key.strip()
        value = value.strip()
        if value:
            current_item[key] = parse_scalar(value)
            current_item.pop("__pending_lists__", None)
        else:
            flush_nested_item()
            current_item[key] = []
            current_item["__pending_lists__"] = {"key": key}
    flush_current_item()
    return data
