#!/usr/bin/env python3
"""Validate builder build-catalog inputs for the release install path."""

import argparse
import json
import re
import sys
from pathlib import Path
from pathlib import PurePosixPath
from typing import Any, Optional
from urllib.parse import urlparse

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from config_query import load_config  # noqa: E402

OCI_REPO_RE = re.compile(r"^[a-z0-9]+([._/-][a-z0-9]+)*$")
MAKE_TARGET_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$")

def lookup(data: dict, path: str, default: Any = "") -> Any:
    value: Any = data
    for part in path.split("."):
        if not isinstance(value, dict) or part not in value:
            return default
        value = value[part]
    return value


def as_bool(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes", "on"}
    return False


def as_str(value: Any) -> str:
    if value is None:
        return ""
    return str(value).strip()


def shell_join(parts: list[str]) -> str:
    return " ".join(shlex.quote(part) for part in parts)


def validate_builder_workflow(config: dict) -> list[str]:
    errors: list[str] = []
    workflow_prefix = "client_verification.builder.workflow"
    if not as_bool(lookup(config, f"{workflow_prefix}.enabled", False)):
        errors.append("client_verification.builder.workflow.enabled must be true for final builder workflow evidence")
    for key in ("workspace_name", "work_profile", "repo", "source_ref", "target_name"):
        if not as_str(lookup(config, f"{workflow_prefix}.{key}", "")):
            errors.append(f"{workflow_prefix}.{key} is required for final builder workflow evidence")
    source_ref = as_str(lookup(config, f"{workflow_prefix}.source_ref", ""))
    if source_ref and (
        len(source_ref) != 40 or not all(char in "0123456789abcdef" for char in source_ref)
    ):
        errors.append(f"{workflow_prefix}.source_ref must be a 40-character lowercase commit SHA")
    for key in ("poll_attempts", "poll_delay_seconds"):
        raw = lookup(config, f"{workflow_prefix}.{key}", "")
        if raw == "":
            continue
        try:
            value = int(raw)
        except (TypeError, ValueError):
            errors.append(f"{workflow_prefix}.{key} must be a positive integer")
            continue
        if value <= 0:
            errors.append(f"{workflow_prefix}.{key} must be a positive integer")
    return errors


def file_error(config_path: Path, value: str, label: str) -> Optional[str]:
    if not value:
        return None
    path = Path(value).expanduser()
    if not path.is_absolute():
        path = config_path.parent / path
    if not path.is_file():
        return f"{label} does not exist: {path}"
    return None


def resolve_config_relative_path(config_path: Path, value: str) -> Path:
    path = Path(value).expanduser()
    if not path.is_absolute():
        path = config_path.parent / path
    return path


def resolved_config_path_str(config_path: Path, value: str) -> Optional[str]:
    if not value:
        return None
    return str(resolve_config_relative_path(config_path, value).resolve())


def parse_source_credential_scalar(raw: str) -> str:
    raw = raw.strip()
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in {"'", '"'}:
        return raw[1:-1]
    return raw


def parse_simple_list_manifest(path: Path) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8")
    stripped = text.lstrip()
    if stripped.startswith("{") or stripped.startswith("["):
        data = json.loads(text)
        if not isinstance(data, dict):
            raise ValueError("must contain a JSON object")
        return data

    data: dict[str, Any] = {}
    current_key = ""
    current_item: Optional[dict[str, str]] = None
    nested_item: Optional[dict[str, Any]] = None

    def flush_nested_item() -> None:
        nonlocal nested_item
        if current_item is None or nested_item is None:
            return
        pending_lists = current_item.get("__pending_lists__")
        if not isinstance(pending_lists, dict):
            nested_item = None
            return
        pending_key = as_str(pending_lists.get("key", ""))
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
                data[current_key] = parse_source_credential_scalar(value)
            else:
                data.setdefault(current_key, [])
            continue
        if not current_key:
            continue
        if stripped_line.startswith("- "):
            remainder = stripped_line[2:].strip()
            pending_lists = current_item.get("__pending_lists__") if current_item is not None else None
            pending_key = as_str(pending_lists.get("key", "")) if isinstance(pending_lists, dict) else ""
            if pending_key and indent > 2:
                flush_nested_item()
                if remainder and ":" in remainder:
                    nested_item = {}
                    key, value = remainder.split(":", 1)
                    nested_item[key.strip()] = parse_source_credential_scalar(value)
                    continue
                if remainder:
                    current_item.setdefault(pending_key, []).append(parse_source_credential_scalar(remainder))
                    continue
            flush_current_item()
            current_item = {}
            if remainder:
                if ":" not in remainder:
                    raise ValueError("expected key: value after '-'")
                key, value = remainder.split(":", 1)
                current_item[key.strip()] = parse_source_credential_scalar(value)
            continue
        if current_item is None:
            continue
        if nested_item is not None:
            if ":" not in stripped_line:
                raise ValueError("expected key: value in nested list entry")
            key, value = stripped_line.split(":", 1)
            key = key.strip()
            value = value.strip()
            nested_item[key] = parse_source_credential_scalar(value) if value else []
            continue
        if ":" not in stripped_line:
            raise ValueError("expected key: value in list entry")
        key, value = stripped_line.split(":", 1)
        key = key.strip()
        value = value.strip()
        if value:
            current_item[key] = parse_source_credential_scalar(value)
            current_item.pop("__pending_lists__", None)
        else:
            flush_nested_item()
            current_item[key] = []
            current_item["__pending_lists__"] = {"key": key}
    flush_current_item()
    return data


def object_items(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        return []
    return [item for item in value if isinstance(item, dict)]


def item_names(items: list[dict[str, Any]]) -> set[str]:
    return {as_str(item.get("name", "")) for item in items if as_str(item.get("name", ""))}


def build_target_lookup_names(items: list[dict[str, Any]]) -> set[str]:
    names = item_names(items)
    for item in items:
        aliases = item.get("aliases")
        if isinstance(aliases, list):
            names.update(as_str(alias) for alias in aliases if as_str(alias))
    return names


def valid_repo_relative_path(raw: str) -> bool:
    raw = raw.strip()
    if not raw or raw.startswith("/") or "\\" in raw:
        return False
    clean = PurePosixPath(raw)
    parts = clean.parts
    return "." not in parts and ".." not in parts


def validate_build_catalog(config_path: Path, config: dict, build_catalog: str) -> list[str]:
    errors: list[str] = []
    if not build_catalog:
        return errors
    path = resolve_config_relative_path(config_path, build_catalog)
    if not path.is_file():
        return errors
    try:
        catalog = parse_simple_list_manifest(path)
    except Exception as exc:
        return [f"install.build_catalog_path could not be parsed: {exc}"]

    build_targets = object_items(catalog.get("buildTargets"))
    work_profiles = object_items(catalog.get("workProfiles"))
    repos = object_items(catalog.get("repos"))
    if not work_profiles:
        errors.append("install.build_catalog_path must declare at least one workProfiles entry")
    if not repos:
        errors.append("install.build_catalog_path must declare at least one repos entry")
    profile_names = item_names(work_profiles)
    repo_names = item_names(repos)
    target_names = build_target_lookup_names(build_targets)
    profile_repo_names: dict[str, set[str]] = {}
    target_repo_names: dict[str, set[str]] = {}
    for index, profile in enumerate(work_profiles):
        prefix = f"install.build_catalog_path workProfiles[{index}]"
        profile_name = as_str(profile.get("name", ""))
        profile_repos = object_items(profile.get("repos"))
        if profile_name and not profile_repos:
            errors.append(f"{prefix}.repos must declare at least one repo")
            continue
        allowed_repos: set[str] = set()
        for repo_index, profile_repo in enumerate(profile_repos):
            repo_name = as_str(profile_repo.get("name", ""))
            if not repo_name:
                errors.append(f"{prefix}.repos[{repo_index}].name is required")
                continue
            if repo_names and repo_name not in repo_names:
                errors.append(f"{prefix}.repos[{repo_index}].name references unknown repos entry: {repo_name}")
                continue
            if repo_name in allowed_repos:
                errors.append(f"{prefix}.repos[{repo_index}].name duplicates repo {repo_name}")
                continue
            allowed_repos.add(repo_name)
        if profile_name:
            profile_repo_names[profile_name] = allowed_repos
    for index, target in enumerate(build_targets):
        prefix = f"install.build_catalog_path buildTargets[{index}]"
        target_name = as_str(target.get("name", ""))
        if not target_name:
            errors.append(f"{prefix}.name is required")
        target_repo = as_str(target.get("repo", ""))
        if target_repo and repo_names and target_repo not in repo_names:
            errors.append(f"{prefix}.repo references unknown repos entry: {target_repo}")
        lookup_names = [target_name]
        aliases = target.get("aliases")
        if isinstance(aliases, list):
            lookup_names.extend(as_str(alias) for alias in aliases if as_str(alias))
        for lookup_name in lookup_names:
            if lookup_name and target_repo:
                target_repo_names.setdefault(lookup_name, set()).add(target_repo)
        execution = as_str(target.get("execution", ""))
        if execution in {"make_target", "make"}:
            execution = "make"
        elif execution in {"repo_script", "script"}:
            execution = "script"
        args = []
        raw_args = target.get("args")
        if isinstance(raw_args, list):
            args = [as_str(item) for item in raw_args if as_str(item)]
        if not args:
            if execution == "make":
                make_target = as_str(target.get("makeTarget", ""))
                if make_target:
                    args = [make_target]
            elif execution == "script":
                script_path = as_str(target.get("scriptPath", ""))
                args = [script_path or "build.sh"]
        if execution and execution not in {"script", "make"}:
            errors.append(f"{prefix}.execution must be make or script")
        if execution == "script":
            if len(args) != 1:
                errors.append(f"{prefix}.args must contain exactly one script path when execution is script")
            elif not valid_repo_relative_path(args[0]):
                errors.append(f"{prefix}.args[0] must be a relative path inside the repo")
        if execution == "make":
            if len(args) != 1:
                errors.append(f"{prefix}.args must contain exactly one make target when execution is make")
            elif not MAKE_TARGET_RE.match(args[0]):
                errors.append(f"{prefix}.args[0] contains unsupported characters: {args[0]}")
        containerfile_path = as_str(target.get("containerfilePath", ""))
        if containerfile_path and not valid_repo_relative_path(containerfile_path):
            errors.append(f"{prefix}.containerfilePath must be a relative path inside the repo")
        image_repository = as_str(target.get("imageRepository", ""))
        if image_repository and not OCI_REPO_RE.match(image_repository):
            errors.append(f"{prefix}.imageRepository is invalid: {image_repository}")

    for index, repo in enumerate(repos):
        repo_prefix = f"install.build_catalog_path repos[{index}]"
        repo_url = as_str(repo.get("url", ""))
        if not repo_url:
            errors.append(f"{repo_prefix}.url is required")
            continue
        parsed = urlparse(repo_url)
        if parsed.scheme.lower() != "https" or not parsed.hostname:
            errors.append(f"{repo_prefix}.url must be an https URL with a host")

    if as_bool(lookup(config, "client_verification.builder.workflow.enabled", False)):
        workflow_profile = as_str(lookup(config, "client_verification.builder.workflow.work_profile", ""))
        workflow_repo = as_str(lookup(config, "client_verification.builder.workflow.repo", ""))
        workflow_target = as_str(lookup(config, "client_verification.builder.workflow.target_name", ""))
        if workflow_profile and profile_names and workflow_profile not in profile_names:
            errors.append(
                f"client_verification.builder.workflow.work_profile is not declared in build catalog workProfiles: {workflow_profile}"
            )
        if workflow_repo and repo_names and workflow_repo not in repo_names:
            errors.append(
                f"client_verification.builder.workflow.repo is not declared in build catalog repos: {workflow_repo}"
            )
        if workflow_profile and workflow_repo and workflow_profile in profile_repo_names:
            allowed_repos = profile_repo_names[workflow_profile]
            if allowed_repos and workflow_repo not in allowed_repos:
                errors.append(
                    f"client_verification.builder.workflow.repo is not enabled for work_profile {workflow_profile}: {workflow_repo}"
                )
        if workflow_target and target_names and workflow_target not in target_names:
            errors.append(
                f"client_verification.builder.workflow.target_name is not declared in build catalog buildTargets: {workflow_target}"
            )
        if workflow_target and workflow_repo:
            repos_for_target = target_repo_names.get(workflow_target, set())
            if repos_for_target and workflow_repo not in repos_for_target:
                errors.append(
                    f"client_verification.builder.workflow.target_name does not belong to workflow.repo {workflow_repo}: {workflow_target}"
                )
    return errors




def main() -> int:
    parser = argparse.ArgumentParser(description="Validate a builder build catalog against release config inputs.")
    parser.add_argument("--config", required=True)
    parser.add_argument("--build-catalog", required=True)
    parser.add_argument("--output-json")
    args = parser.parse_args()

    config_path = Path(args.config).expanduser().resolve()
    build_catalog = args.build_catalog
    config = load_config(config_path)

    errors = []
    err = file_error(config_path, build_catalog, "install.build_catalog_path")
    if err:
        errors.append(err)
    else:
        errors.extend(validate_build_catalog(config_path, config, build_catalog))

    payload = {
        "configPath": str(config_path),
        "buildCatalogPath": str(resolve_config_relative_path(config_path, build_catalog).resolve()),
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
