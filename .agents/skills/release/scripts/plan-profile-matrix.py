#!/usr/bin/env python3
"""Generate reproducible appliance profile-matrix release commands.

This script plans the real-environment commands but never executes them.
"""

import argparse
from datetime import datetime, timezone
import json
import re
import shlex
import sys
from pathlib import PurePosixPath
from pathlib import Path
from typing import Any, Optional
from urllib.parse import urlparse

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from config_query import load_config  # noqa: E402


PROFILES = ("core", "storage", "builder")
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


def item_ids(items: list[dict[str, Any]]) -> set[str]:
    return {as_str(item.get("id", "")) for item in items if as_str(item.get("id", ""))}


def build_target_lookup_names(items: list[dict[str, Any]]) -> set[str]:
    names = item_names(items)
    for item in items:
        aliases = item.get("aliases")
        if isinstance(aliases, list):
            names.update(as_str(alias) for alias in aliases if as_str(alias))
    return names


def git_url_host(raw: str) -> str:
    raw = raw.strip()
    if not raw:
        return ""
    parsed = urlparse(raw)
    if parsed.hostname:
        return parsed.hostname
    if ":" in raw and "/" not in raw.split(":", 1)[0]:
        before_colon = raw.split(":", 1)[0]
        if "@" in before_colon:
            return before_colon.split("@", 1)[1]
    return ""


def is_ssh_git_url(raw: str) -> bool:
    raw = raw.strip()
    if not raw:
        return False
    parsed = urlparse(raw)
    if parsed.scheme == "ssh":
        return True
    return ":" in raw and "/" not in raw.split(":", 1)[0] and "@" in raw.split(":", 1)[0]


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


def build_command(script_path: Path, config_path: Path, profile: str, release_version: str, build_catalog: str) -> list[str]:
    args = ["bash", str(script_path), "--config", str(config_path), "--appliance-profile", profile, "--uninstall-first", "--final-ok"]
    if release_version:
        args.extend(["--release-version", release_version])
    if profile != "core":
        args.append("--skip-build")
    if profile == "builder":
        if build_catalog:
            args.extend(["--build-catalog", build_catalog])
    return args


def build_audit_command(script_path: Path, plan_json: Optional[Path], require_builder_workflow: bool) -> list[str]:
    args = [
        "python3",
        str(script_path),
        "--core-run-dir",
        "<core-run-dir>",
        "--storage-run-dir",
        "<storage-run-dir>",
        "--builder-run-dir",
        "<builder-run-dir>",
    ]
    if plan_json:
        args.extend(["--plan-json", str(plan_json)])
    if require_builder_workflow:
        args.append("--require-builder-workflow")
    args.extend(["--output-json", "<profile-matrix-audit.json>"])
    return args


def suggested_final_config_overlay() -> str:
    release_repo = SCRIPT_DIR.parents[3]
    catalog = release_repo / ".agents" / "skills" / "release" / "references" / "build-catalog.example.yaml"
    return "\n".join(
        [
            "build_flow:",
            "  # Optional: omit these to let the build host package docker.io/alpine/git:latest",
            "  # as registry.local/workspace-provisioner@sha256:... automatically.",
            "  workspace_provisioner_image_archive_source: /abs/path/on/build-host/workspace-provisioner.oci.tar",
            "  workspace_provisioner_image_ref: registry.local/workspace-provisioner@sha256:<real-64-hex-image-digest>",
            "",
            "install:",
            "  appliance_profile: builder",
            f"  build_catalog_path: {catalog}",
            "",
            "client_verification:",
            "  builder:",
            "    workflow:",
            "      enabled: true",
            "      workspace_name: release-smoke",
            "      work_profile: builder",
            "      repo: app",
            "      # Immutable lowercase 40-character commit SHA from the repo being built.",
            "      source_ref: 0123456789abcdef0123456789abcdef01234567",
            "      target_name: app",
            "      poll_attempts: 60",
            "      poll_delay_seconds: 5",
            "      expect_success: true",
        ]
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Plan, but do not run, the final appliance profile matrix.")
    parser.add_argument("--config", required=True)
    parser.add_argument("--release-version", default="")
    parser.add_argument("--output-json")
    parser.add_argument("--output-md")
    parser.add_argument("--require-builder-workflow", action="store_true")
    parser.add_argument("--document-title", default="Appliance Profile Matrix Plan")
    parser.add_argument("--checklist-only", action="store_true")
    args = parser.parse_args()

    config_path = Path(args.config).expanduser().resolve()
    config = load_config(config_path)
    release_version = args.release_version or as_str(lookup(config, "release.version", ""))
    build_catalog = as_str(lookup(config, "install.build_catalog_path", ""))
    script_path = SCRIPT_DIR / "run-release-flow.sh"
    audit_script_path = SCRIPT_DIR / "audit-profile-matrix-reports.py"

    validation_errors: list[str] = []
    for value, label in ((build_catalog, "install.build_catalog_path"),):
        error = file_error(config_path, value, label)
        if error:
            validation_errors.append(error)
    validation_errors.extend(validate_build_catalog(config_path, config, build_catalog))
    if args.require_builder_workflow:
        validation_errors.extend(validate_builder_workflow(config))
        if not build_catalog:
            validation_errors.append("install.build_catalog_path is required for final builder workflow evidence")

    commands = []
    for profile in PROFILES:
        argv = build_command(script_path, config_path, profile, release_version, build_catalog)
        commands.append(
            {
                "profile": profile,
                "argv": argv,
                "command": shell_join(argv),
                "reusesPublishedBuild": profile != "core",
            }
        )
    out_json = Path(args.output_json).expanduser().resolve() if args.output_json else None
    audit_argv = build_audit_command(audit_script_path, out_json, args.require_builder_workflow)
    audit_command = {
        "argv": audit_argv,
        "command": shell_join(audit_argv),
        "requiresBuilderWorkflow": bool(args.require_builder_workflow),
    }

    if args.checklist_only:
        notes = [
            "This checklist does not execute commands and is not a live run plan.",
            "Fill every validation error, then run make plan-final-profile-matrix.",
            "Use final-profile-matrix-plan.md, not this checklist, for live profile-matrix commands.",
        ]
    else:
        notes = [
            "This planner does not execute commands.",
            "Run commands sequentially against the real target; each command uses --uninstall-first for clean profile evidence.",
            "The core command performs build/publish; storage and builder use --skip-build to reuse the same complete bundle.",
            "Each real run writes metadata/release-report.json and release-report.md in its run directory.",
            "After all three runs finish, replace the audit command placeholders with the real run directories and run it locally.",
        ]
    evidence_review_checklist = [
        "Confirm each run's metadata/release-report.json has succeeded build/publish, install, target verification, and client verification steps.",
        "Confirm each run's release-report.md has no failed or missing unskipped step.",
        "For core and storage runs, confirm disabled builder REST/MCP evidence shows build routes/tools are absent.",
        "For the builder run, confirm builder REST/MCP tool evidence is present.",
        "For final builder workflow evidence, confirm the optional workflow smoke succeeded, produced a non-empty artifactRef, and returned no managed builder Git Secret names or private-key markers in job, step, or log evidence.",
    ]

    plan = {
        "checklistOnly": bool(args.checklist_only),
        "configPath": str(config_path),
        "generatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "releaseVersion": release_version or None,
        "readyForFinalPlan": not bool(validation_errors),
        "buildCatalogPath": resolved_config_path_str(config_path, build_catalog),
        "profiles": list(PROFILES),
        "validationErrors": validation_errors,
        "commands": [] if args.checklist_only else commands,
        "auditCommand": None if args.checklist_only else audit_command,
        "suggestedConfigOverlay": suggested_final_config_overlay() if args.checklist_only else None,
        "notes": notes,
        "evidenceReviewChecklist": evidence_review_checklist,
    }

    if out_json:
        out_json.parent.mkdir(parents=True, exist_ok=True)
        out_json.write_text(json.dumps(plan, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    out_md = Path(args.output_md).expanduser().resolve() if args.output_md else None
    if out_md:
        lines = [f"# {args.document_title}", "", f"- Generated at: `{plan['generatedAt']}`", ""]
        if args.checklist_only:
            lines.extend(["## Status", ""])
            if validation_errors:
                lines.append("- Final inputs are not complete yet. Do not run the live profile matrix from this checklist.")
            else:
                lines.append("- Final inputs look complete. Generate the fail-closed final plan before running any live profile matrix command.")
            lines.append("")
        if validation_errors:
            lines.extend(["## Validation Errors", ""])
            lines.extend(f"- {error}" for error in validation_errors)
            lines.append("")
        if args.checklist_only:
            lines.extend(
                [
                    "## Suggested Config Overlay",
                    "",
                    "Use this as a secret-free starting point, then replace every placeholder path, digest, repo, target, and commit SHA with real product values.",
                    "",
                    "```yaml",
                    plan["suggestedConfigOverlay"] or "",
                    "```",
                    "",
                ]
            )
        lines.extend(
            [
                "## Resolved Inputs",
                "",
                f"- Config: {config_path}",
                f"- Release version: {release_version or '(from generated release metadata)'}",
                f"- Build catalog: {resolved_config_path_str(config_path, build_catalog) or '(not configured)'}",
                "",
            ]
        )
        lines.extend(["## Notes", ""])
        lines.extend(f"- {note}" for note in notes)
        lines.append("")
        if args.checklist_only:
            lines.extend(
                [
                    "## Next Command",
                    "",
                    "```bash",
                    "make plan-final-profile-matrix CONFIG=/abs/path/to/appliance-release.config.yaml",
                    "```",
                ]
            )
        else:
            lines.extend(["## Commands", ""])
            for command in commands:
                lines.extend([f"### {command['profile']}", "", "```bash", command["command"], "```", ""])
            lines.extend(["## Post-Run Audit Command", "", "```bash", audit_command["command"], "```", ""])
            lines.extend(["## Evidence Review Checklist", ""])
            lines.extend(f"- {item}" for item in evidence_review_checklist)
        lines.append("")
        out_md.parent.mkdir(parents=True, exist_ok=True)
        out_md.write_text("\n".join(lines), encoding="utf-8")
    print(json.dumps(plan, indent=2, sort_keys=True))
    return 1 if validation_errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
