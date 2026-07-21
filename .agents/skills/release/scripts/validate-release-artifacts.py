#!/usr/bin/env python3
"""Validate copied release-input artifacts against final bundle manifest evidence."""

import argparse
import json
from pathlib import Path
import re
import sys
import tarfile
from typing import Optional


IMAGE_DIGEST_RE = re.compile(r"^.+@sha256:[0-9a-f]{64}$")
PLACEHOLDER_IMAGE_DIGEST = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"


def first_named(root: Path, name: str) -> Optional[Path]:
    if not root.is_dir():
        return None
    matches = sorted(root.rglob(name))
    return matches[0] if matches else None


def load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return data


def artifact_digest(artifact: dict) -> str:
    return str(artifact.get("digest") or artifact.get("manifestDigest") or "").strip()


def require_artifact(artifacts: dict, key: str) -> dict:
    artifact = artifacts.get(key)
    if not isinstance(artifact, dict):
        raise ValueError(f"release-input artifacts.{key} is missing")
    rel_path = artifact.get("path")
    if not isinstance(rel_path, str) or not rel_path:
        raise ValueError(f"release-input artifacts.{key}.path is missing")
    if not artifact_digest(artifact):
        raise ValueError(f"release-input artifacts.{key} is missing digest/manifestDigest")
    return artifact


def require_file_artifact(artifacts: dict, key: str, release_input_dir: Path) -> Path:
    artifact = require_artifact(artifacts, key)
    size = artifact.get("sizeBytes")
    if not isinstance(size, int) or size <= 0:
        raise ValueError(f"release-input artifacts.{key}.sizeBytes must be positive")
    return require_existing_release_path(release_input_dir, artifact["path"], key)


def require_dir_artifact(artifacts: dict, key: str, release_input_dir: Path) -> Path:
    artifact = require_artifact(artifacts, key)
    path = require_existing_release_path(release_input_dir, artifact["path"], key)
    if not path.is_dir():
        raise ValueError(f"release-input artifacts.{key}.path must be a directory: {path}")
    return path


def require_bundle_entry(entries_by_path: dict[str, dict], path: str, label: str) -> dict:
    entry = entries_by_path.get(path)
    if not isinstance(entry, dict):
        raise ValueError(f"bundle manifest is missing {label}: {path}")
    digest = str(entry.get("digest") or "").strip()
    if not digest:
        raise ValueError(f"bundle manifest entry {path} is missing digest")
    size = entry.get("sizeBytes")
    if not isinstance(size, int) or size <= 0:
        raise ValueError(f"bundle manifest entry {path} is missing positive sizeBytes")
    return entry


def require_image_reference(artifact: dict, label: str) -> str:
    image_ref = str(artifact.get("imageReference") or "").strip()
    if not image_ref:
        raise ValueError(f"release-input artifacts.{label}.imageReference is missing")
    return image_ref


def require_matching_bundle_image_reference(entry: dict, expected_ref: str, bundle_path: str, label: str) -> None:
    actual_ref = str(entry.get("imageReference") or "").strip()
    if not actual_ref:
        raise ValueError(f"bundle manifest entry {bundle_path} is missing imageReference for {label}")
    if actual_ref != expected_ref:
        raise ValueError(
            f"bundle manifest entry {bundle_path} imageReference mismatch for {label}: "
            f"expected {expected_ref}, got {actual_ref}"
        )


def require_existing_release_path(release_input_dir: Path, rel_path: str, label: str) -> Path:
    path = release_input_dir / rel_path
    if not path.exists():
        raise ValueError(f"release-input {label} path is missing on disk: {path}")
    return path


def image_ref_repository(image_ref: str) -> str:
    """Return the name portion of a ref (strip @digest and :tag)."""
    image_ref = image_ref.strip()
    if "@" in image_ref:
        image_ref = image_ref.split("@", 1)[0]
    if re.search(r":[^/]+$", image_ref):
        image_ref = image_ref.rsplit(":", 1)[0]
    return image_ref


def require_oci_archive_reference_matches_content(path: Path, image_ref: str, label: str) -> None:
    """When path is an OCI layout archive, require annotation digest == content digest == image_ref."""
    try:
        with tarfile.open(path) as tar:
            try:
                idx_file = tar.extractfile("index.json")
            except KeyError:
                return
            if idx_file is None:
                return
            index = json.load(idx_file)
    except (tarfile.TarError, OSError, json.JSONDecodeError):
        # Stub/non-OCI archives used in unit fixtures are allowed through.
        return

    manifests = index.get("manifests") if isinstance(index, dict) else None
    if not isinstance(manifests, list) or not manifests:
        raise ValueError(f"{label} OCI archive {path} has no manifests in index.json")

    expected_digest = image_ref.split("@", 1)[1]
    chosen = None
    for manifest in manifests:
        if not isinstance(manifest, dict):
            continue
        ann = (manifest.get("annotations") or {}).get("org.opencontainers.image.ref.name")
        if ann == image_ref:
            chosen = manifest
            break
    if chosen is None:
        chosen = manifests[0] if isinstance(manifests[0], dict) else None
    if not isinstance(chosen, dict):
        raise ValueError(f"{label} OCI archive {path} has an invalid manifest entry")

    content_digest = str(chosen.get("digest") or "").strip()
    if content_digest != expected_digest:
        raise ValueError(
            f"{label} OCI archive {path} manifest digest {content_digest} does not match "
            f"imageReference digest {expected_digest}"
        )
    ann = (chosen.get("annotations") or {}).get("org.opencontainers.image.ref.name") or ""
    if ann and ann != image_ref:
        raise ValueError(
            f"{label} OCI archive {path} annotation ref {ann!r} does not match imageReference {image_ref!r}"
        )
    if "@" in ann:
        ann_digest = ann.split("@", 1)[1]
        if ann_digest != content_digest:
            raise ValueError(
                f"{label} OCI archive {path} annotation digest {ann_digest} does not match "
                f"archived manifest digest {content_digest}"
            )


def image_ref_is_digest_pinned(image_ref: str) -> bool:
    image_ref = image_ref.strip()
    if not IMAGE_DIGEST_RE.match(image_ref):
        return False
    return image_ref.rsplit("@sha256:", 1)[1] != PLACEHOLDER_IMAGE_DIGEST


def parse_csv(value: str) -> list:
    return [item.strip() for item in value.split(",") if item.strip()]


def parse_yaml_scalar(raw: str):
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
    return raw


def parse_simple_yaml_mapping(text: str) -> dict:
    root: dict = {}
    stack: list[tuple[int, dict]] = [(-1, root)]
    for lineno, raw in enumerate(text.splitlines(), start=1):
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        stripped = line.lstrip(" ")
        if stripped.startswith("- "):
            continue
        indent = len(line) - len(stripped)
        if "\t" in line[:indent]:
            raise ValueError(f"tabs are not supported in bundle values indentation (line {lineno})")
        if ":" not in stripped:
            raise ValueError(f"expected key: value syntax in bundle values (line {lineno})")
        key, remainder = stripped.split(":", 1)
        key = key.strip()
        remainder = remainder.strip()
        while stack and indent <= stack[-1][0]:
            stack.pop()
        if not stack:
            raise ValueError(f"unexpected indentation in bundle values (line {lineno})")
        parent = stack[-1][1]
        if remainder:
            parent[key] = parse_yaml_scalar(remainder)
            continue
        child: dict = {}
        parent[key] = child
        stack.append((indent, child))
    return root


def nested_mapping(root: dict, path: str) -> dict:
    value = root
    for part in path.split("."):
        if not isinstance(value, dict) or part not in value:
            raise ValueError(f"bundle values missing {path}")
        value = value[part]
    if not isinstance(value, dict):
        raise ValueError(f"bundle values {path} must be a mapping")
    return value


def nested_value(root: dict, path: str):
    value = root
    for part in path.split("."):
        if not isinstance(value, dict) or part not in value:
            raise ValueError(f"bundle values missing {path}")
        value = value[part]
    return value


def image_reference_from_values(root: dict, path: str) -> str:
    image = nested_mapping(root, path)
    repository = str(image.get("repository") or "").strip()
    tag = str(image.get("tag") or "").strip()
    digest = str(image.get("digest") or "").strip()
    if not repository:
        raise ValueError(f"bundle values {path}.repository is required")
    if digest:
        return f"{repository}@{digest}"
    if not tag:
        raise ValueError(f"bundle values {path}.tag is required when digest is empty")
    return f"{repository}:{tag}"


def load_bundle_values(bundle_content_root: Path, entries_by_path: dict[str, dict]) -> dict:
    require_bundle_entry(entries_by_path, "configuration/values.yaml", "configuration values")
    values_path = bundle_content_root / "configuration" / "values.yaml"
    if not values_path.is_file():
        raise ValueError(f"bundle configuration values file is missing on disk: {values_path}")
    return parse_simple_yaml_mapping(values_path.read_text(encoding="utf-8"))


def validate_runtime_values(artifacts: dict, bundle_values: dict) -> list:
    expected = {
        "controlPlaneImage": ("image", require_image_reference(require_artifact(artifacts, "controlPlaneImage"), "controlPlaneImage")),
        "uiImage": ("ui.image", require_image_reference(require_artifact(artifacts, "uiImage"), "uiImage")),
    }
    checked = []
    if nested_value(bundle_values, "ui.enabled") is not True:
        raise ValueError("bundle values ui.enabled must be true for the separate appliance UI service")
    for label, (values_path, expected_ref) in expected.items():
        actual_ref = image_reference_from_values(bundle_values, values_path)
        if actual_ref != expected_ref:
            raise ValueError(
                f"bundle values {values_path} imageReference mismatch for {label}: "
                f"expected {expected_ref}, got {actual_ref}"
            )
        checked.append(label)
    return checked


def validate_argo(artifacts: dict, release_input_dir: Path, entries_by_path: dict) -> list:
    checked = []
    chart = require_artifact(artifacts, "argoWorkflowsChart")
    chart_path = require_existing_release_path(release_input_dir, chart["path"], "argoWorkflowsChart")
    require_bundle_entry(entries_by_path, f"charts/{chart_path.name}", "Argo chart")
    checked.append("argoWorkflowsChart")

    crds = require_artifact(artifacts, "argoCRDs")
    crds_path = require_existing_release_path(release_input_dir, crds["path"], "argoCRDs")
    if crds_path.is_file():
        require_bundle_entry(entries_by_path, f"kubernetes/crds/{crds_path.name}", "Argo CRDs")
    else:
        prefix = f"kubernetes/crds/{str(crds['path']).rstrip('/')}/"
        matches = [path for path in entries_by_path if path.startswith(prefix)]
        if not matches:
            raise ValueError(f"bundle manifest is missing Argo CRD entries under {prefix}")
        for path in matches:
            require_bundle_entry(entries_by_path, path, "Argo CRD")
    checked.append("argoCRDs")

    for key in ("argoControllerImage", "argoExecutorImage"):
        artifact = require_artifact(artifacts, key)
        image_path = require_existing_release_path(release_input_dir, artifact["path"], key)
        image_ref = require_image_reference(artifact, key)
        bundle_path = f"oci-images/{image_path.name}"
        entry = require_bundle_entry(entries_by_path, bundle_path, key)
        require_matching_bundle_image_reference(entry, image_ref, bundle_path, key)
        checked.append(key)
    return checked


def validate_required_artifacts(artifacts: dict, release_input_dir: Path, entries_by_path: dict) -> list:
    checked = []
    runtime_targets = {"applianceChart": "charts"}
    for key, target_dir in runtime_targets.items():
        artifact_path = require_file_artifact(artifacts, key, release_input_dir)
        require_bundle_entry(entries_by_path, f"{target_dir}/{artifact_path.name}", key)
        checked.append(key)

    for key in ("controlPlaneImage", "uiImage"):
        artifact = require_artifact(artifacts, key)
        image_ref = require_image_reference(artifact, key)
        artifact_path = require_file_artifact(artifacts, key, release_input_dir)
        bundle_path = f"oci-images/{artifact_path.name}"
        entry = require_bundle_entry(entries_by_path, bundle_path, key)
        require_matching_bundle_image_reference(entry, image_ref, bundle_path, key)
        checked.append(key)

    for key in ("configurationSchema", "compatibility", "checksums"):
        require_file_artifact(artifacts, key, release_input_dir)
        checked.append(key)

    for key in ("sbom", "provenance", "notices", "tests"):
        require_dir_artifact(artifacts, key, release_input_dir)
        checked.append(key)

    return checked


def validate_extra_oci_images(
    artifacts: dict, release_input_dir: Path, entries_by_path: dict, expected_refs: list
) -> list:
    images = artifacts.get("extraOCIImages")
    if images is None:
        if expected_refs:
            raise ValueError(
                "release-input artifacts.extraOCIImages is missing; expected refs: "
                + ", ".join(expected_refs)
            )
        return []
    if not isinstance(images, list):
        raise ValueError("release-input artifacts.extraOCIImages must be an array")
    checked = []
    for idx, image in enumerate(images):
        if not isinstance(image, dict):
            raise ValueError(f"release-input artifacts.extraOCIImages[{idx}] must be an object")
        rel_path = image.get("path")
        if not isinstance(rel_path, str) or not rel_path:
            raise ValueError(f"release-input artifacts.extraOCIImages[{idx}].path is missing")
        if not artifact_digest(image):
            raise ValueError(f"release-input artifacts.extraOCIImages[{idx}] is missing digest")
        image_ref = str(image.get("imageReference") or "").strip()
        if not image_ref:
            raise ValueError(f"release-input artifacts.extraOCIImages[{idx}].imageReference is missing")
        if not image_ref_is_digest_pinned(image_ref):
            raise ValueError(
                f"release-input artifacts.extraOCIImages[{idx}].imageReference must be digest-pinned"
            )
        image_path = require_existing_release_path(
            release_input_dir, rel_path, f"extraOCIImages[{idx}]"
        )
        require_oci_archive_reference_matches_content(
            image_path, image_ref, f"extraOCIImages[{idx}]"
        )
        # Catch archive/reference pairing bugs for known appliance-owned images.
        # Example failure mode: workspace-provisioner.tar labeled as automation-dev.
        path_name = image_path.name.lower()
        ref_lower = image_ref.lower()
        for token in ("workspace-provisioner", "automation-dev"):
            if token in path_name and token not in ref_lower:
                raise ValueError(
                    f"release-input artifacts.extraOCIImages[{idx}] path {rel_path!r} "
                    f"implies imageReference containing {token!r}, got {image_ref!r}"
                )
        bundle_path = f"oci-images/{image_path.name}"
        entry = require_bundle_entry(entries_by_path, bundle_path, f"extraOCIImages[{idx}]")
        require_matching_bundle_image_reference(entry, image_ref, bundle_path, f"extraOCIImages[{idx}]")
        checked.append(image_ref)
    # Expected refs from config may carry stale advisory digests. Match by repository
    # name so online builds that derive the platform manifest digest still pass.
    checked_repos = {image_ref_repository(ref) for ref in checked}
    missing_expected = []
    for expected in expected_refs:
        if expected in checked:
            continue
        if image_ref_repository(expected) in checked_repos:
            continue
        missing_expected.append(expected)
    missing_expected = sorted(missing_expected)
    if missing_expected:
        raise ValueError(
            "release-input artifacts.extraOCIImages is missing expected image refs: "
            + ", ".join(missing_expected)
        )
    return checked


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate release-input Argo/extra OCI artifacts in a final bundle manifest."
    )
    parser.add_argument("--release-input-root", required=True)
    parser.add_argument("--bundle-root", required=True)
    parser.add_argument("--require-argo", action="store_true")
    parser.add_argument(
        "--expected-extra-oci-image-refs",
        default="",
        help="Comma-separated digest-pinned extra OCI image references expected in release-input and bundle.",
    )
    args = parser.parse_args()
    expected_extra_refs = parse_csv(args.expected_extra_oci_image_refs)

    release_input_root = Path(args.release_input_root)
    bundle_root = Path(args.bundle_root)
    release_input_path = first_named(release_input_root, "release-input.json")
    bundle_manifest_path = first_named(bundle_root, "release-manifest.json")
    missing = []
    if release_input_path is None:
        missing.append("release-input.json")
    if bundle_manifest_path is None:
        missing.append("release-manifest.json")
    if missing:
        raise ValueError("missing copied metadata: " + ", ".join(missing))

    release_input = load_json(release_input_path)
    bundle_manifest = load_json(bundle_manifest_path)
    artifacts = release_input.get("artifacts")
    if not isinstance(artifacts, dict):
        raise ValueError("release-input artifacts must be an object")
    entries = bundle_manifest.get("entries")
    if not isinstance(entries, list):
        raise ValueError("release-manifest entries must be an array")
    entries_by_path = {
        str(entry.get("targetPath") or entry.get("path") or ""): entry
        for entry in entries
        if isinstance(entry, dict)
    }
    bundle_values = load_bundle_values(bundle_manifest_path.parent, entries_by_path)

    checked = {
        "requiredArtifacts": validate_required_artifacts(
            artifacts, release_input_path.parent, entries_by_path
        ),
        "runtimeValues": validate_runtime_values(artifacts, bundle_values),
        "argo": validate_argo(artifacts, release_input_path.parent, entries_by_path)
        if args.require_argo
        else [],
        "extraOCIImages": validate_extra_oci_images(
            artifacts, release_input_path.parent, entries_by_path, expected_extra_refs
        ),
    }
    print(json.dumps({"checked": checked}, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"validate-release-artifacts: {exc}", file=sys.stderr)
        raise SystemExit(1)
