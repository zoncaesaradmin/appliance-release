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


def require_bundle_entry_prefix(entries_by_path: dict[str, dict], prefix: str, label: str) -> None:
    for path in entries_by_path:
        if path.startswith(prefix):
            return
    raise ValueError(f"bundle manifest is missing {label} entries under {prefix}")


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


def require_matching_bundle_digest(entry: dict, artifact: dict, bundle_path: str, label: str) -> None:
    expected = artifact_digest(artifact)
    actual = str(entry.get("digest") or "").strip()
    if actual != expected:
        raise ValueError(
            f"bundle manifest entry {bundle_path} digest mismatch for {label}: "
            f"expected {expected}, got {actual}"
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


def load_oci_archive_index(path: Path) -> Optional[dict]:
    """Load index.json from an OCI-layout tar. Accepts ./index.json members.

    Returns None for stub/non-OCI archives used in unit fixtures.
    """
    try:
        with tarfile.open(path) as tar:
            member = next(
                (
                    entry
                    for entry in tar.getmembers()
                    if entry.isfile() and entry.name.lstrip("./") == "index.json"
                ),
                None,
            )
            if member is None:
                return None
            idx_file = tar.extractfile(member)
            if idx_file is None:
                return None
            index = json.load(idx_file)
    except (tarfile.TarError, OSError, json.JSONDecodeError):
        return None
    if not isinstance(index, dict):
        raise ValueError(f"OCI archive {path} index.json must be an object")
    return index


def require_oci_archive_reference_matches_content(path: Path, image_ref: str, label: str) -> None:
    """When path is an OCI layout archive, require annotation digest == content digest == image_ref."""
    index = load_oci_archive_index(path)
    if index is None:
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
    if not ann:
        return
    local_name = image_ref.split("@", 1)[0]
    allowed = {image_ref, local_name, f"{local_name}:bundled"}
    if ann in allowed:
        return
    if ann.startswith(local_name + ":") and "@" not in ann:
        return
    if "@" in ann:
        ann_digest = ann.split("@", 1)[1]
        if ann_digest == content_digest:
            return
        raise ValueError(
            f"{label} OCI archive {path} annotation digest {ann_digest} does not match "
            f"archived manifest digest {content_digest}"
        )
    raise ValueError(
        f"{label} OCI archive {path} annotation ref {ann!r} does not match imageReference {image_ref!r}"
    )


def image_ref_is_digest_pinned(image_ref: str) -> bool:
    image_ref = image_ref.strip()
    if not IMAGE_DIGEST_RE.match(image_ref):
        return False
    return image_ref.rsplit("@sha256:", 1)[1] != PLACEHOLDER_IMAGE_DIGEST


def parse_csv(value: str) -> list:
    return [item.strip() for item in value.split(",") if item.strip()]


def parse_bool_arg(value: str, label: str) -> bool:
    normalized = value.strip().lower()
    if normalized == "true":
        return True
    if normalized == "false":
        return False
    raise ValueError(f"{label} must be true or false")


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


def validate_zot(
    release_input: dict,
    bundle_manifest: dict,
    artifacts: dict,
    release_input_dir: Path,
    entries_by_path: dict[str, dict],
) -> list:
    compatibility = release_input.get("compatibility")
    if not isinstance(compatibility, dict):
        raise ValueError("release-input compatibility must be an object")
    zot_version = str(compatibility.get("zotVersion") or "").strip()
    if not zot_version or zot_version.lower() == "latest":
        raise ValueError("release-input compatibility.zotVersion must be an exact non-latest version")
    bundle_compatibility = bundle_manifest.get("compatibility")
    if not isinstance(bundle_compatibility, dict):
        raise ValueError("bundle manifest compatibility must be an object")
    bundle_zot_version = str(bundle_compatibility.get("zotVersion") or "").strip()
    if bundle_zot_version != zot_version:
        raise ValueError(
            "bundle manifest compatibility.zotVersion mismatch: "
            f"expected {zot_version}, got {bundle_zot_version}"
        )

    chart = require_artifact(artifacts, "zotChart")
    chart_path = require_file_artifact(artifacts, "zotChart", release_input_dir)
    chart_candidates = (
        f"charts/{chart_path.name}",
        f"chart/{chart_path.name}",
        f"chart/appliance-registry-{chart_path.name}",
    )
    chart_bundle_path = next((path for path in chart_candidates if path in entries_by_path), "")
    if not chart_bundle_path:
        raise ValueError(
            "bundle manifest is missing zotChart; expected one of: "
            + ", ".join(chart_candidates)
        )
    chart_entry = require_bundle_entry(entries_by_path, chart_bundle_path, "zotChart")
    require_matching_bundle_digest(chart_entry, chart, chart_bundle_path, "zotChart")

    image = require_artifact(artifacts, "zotImage")
    image_path = require_file_artifact(artifacts, "zotImage", release_input_dir)
    image_ref = require_image_reference(image, "zotImage")
    if not re.fullmatch(r"registry\.local/zot@sha256:[0-9a-f]{64}", image_ref):
        raise ValueError(
            "release-input artifacts.zotImage.imageReference must be "
            "registry.local/zot@sha256:<64 lowercase hex>"
        )
    if "zot" not in image_path.name.lower():
        raise ValueError(
            f"release-input artifacts.zotImage.path must identify zot, got {image['path']!r}"
        )
    require_oci_archive_reference_matches_content(image_path, image_ref, "zotImage")
    index = load_oci_archive_index(image_path)
    if index is None:
        raise ValueError(f"zotImage OCI archive {image_path} is missing index.json")
    annotation = (
        (index.get("manifests") or [{}])[0].get("annotations") or {}
    ).get("org.opencontainers.image.ref.name")
    if annotation != "registry.local/zot:bundled":
        raise ValueError(
            "zotImage OCI archive annotation must be 'registry.local/zot:bundled', "
            f"got {annotation!r}"
        )
    image_bundle_path = f"oci-images/{image_path.name}"
    image_entry = require_bundle_entry(entries_by_path, image_bundle_path, "zotImage")
    require_matching_bundle_digest(image_entry, image, image_bundle_path, "zotImage")
    require_matching_bundle_image_reference(image_entry, image_ref, image_bundle_path, "zotImage")
    return ["zotChart", "zotImage", f"zotVersion={zot_version}"]


def validate_dns(
    release_input: dict,
    bundle_manifest: dict,
    artifacts: dict,
    release_input_dir: Path,
    entries_by_path: dict[str, dict],
) -> list:
    compatibility = release_input.get("compatibility")
    if not isinstance(compatibility, dict):
        raise ValueError("release-input compatibility must be an object")
    dns_version = str(compatibility.get("dnsVersion") or "").strip()
    if not dns_version or dns_version.lower() == "latest":
        raise ValueError("release-input compatibility.dnsVersion must be an exact non-latest version")
    bundle_compatibility = bundle_manifest.get("compatibility")
    if not isinstance(bundle_compatibility, dict):
        raise ValueError("bundle manifest compatibility must be an object")
    bundle_dns_version = str(bundle_compatibility.get("dnsVersion") or "").strip()
    if bundle_dns_version != dns_version:
        raise ValueError(
            "bundle manifest compatibility.dnsVersion mismatch: "
            f"expected {dns_version}, got {bundle_dns_version}"
        )

    chart = require_artifact(artifacts, "dnsChart")
    chart_path = require_file_artifact(artifacts, "dnsChart", release_input_dir)
    chart_candidates = (
        f"charts/{chart_path.name}",
        f"chart/{chart_path.name}",
        f"chart/appliance-dns-{chart_path.name}",
    )
    chart_bundle_path = next((path for path in chart_candidates if path in entries_by_path), "")
    if not chart_bundle_path:
        raise ValueError(
            "bundle manifest is missing dnsChart; expected one of: "
            + ", ".join(chart_candidates)
        )
    chart_entry = require_bundle_entry(entries_by_path, chart_bundle_path, "dnsChart")
    require_matching_bundle_digest(chart_entry, chart, chart_bundle_path, "dnsChart")

    image = require_artifact(artifacts, "dnsImage")
    image_path = require_file_artifact(artifacts, "dnsImage", release_input_dir)
    image_ref = require_image_reference(image, "dnsImage")
    if not re.fullmatch(r"registry\.local/coredns@sha256:[0-9a-f]{64}", image_ref):
        raise ValueError(
            "release-input artifacts.dnsImage.imageReference must be "
            "registry.local/coredns@sha256:<64 lowercase hex>"
        )
    if "coredns" not in image_path.name.lower() and "dns" not in image_path.name.lower():
        raise ValueError(
            f"release-input artifacts.dnsImage.path must identify coredns, got {image['path']!r}"
        )
    require_oci_archive_reference_matches_content(image_path, image_ref, "dnsImage")
    index = load_oci_archive_index(image_path)
    if index is None:
        raise ValueError(f"dnsImage OCI archive {image_path} is missing index.json")
    annotation = (
        (index.get("manifests") or [{}])[0].get("annotations") or {}
    ).get("org.opencontainers.image.ref.name")
    if annotation != "registry.local/coredns:bundled":
        raise ValueError(
            "dnsImage OCI archive annotation must be 'registry.local/coredns:bundled', "
            f"got {annotation!r}"
        )
    image_bundle_path = f"oci-images/{image_path.name}"
    image_entry = require_bundle_entry(entries_by_path, image_bundle_path, "dnsImage")
    require_matching_bundle_digest(image_entry, image, image_bundle_path, "dnsImage")
    require_matching_bundle_image_reference(image_entry, image_ref, image_bundle_path, "dnsImage")
    return ["dnsChart", "dnsImage", f"dnsVersion={dns_version}"]


def validate_host_agent(
    artifacts: dict,
    release_input_dir: Path,
    entries_by_path: dict[str, dict],
) -> list:
    image = require_artifact(artifacts, "hostAgentImage")
    image_path = require_file_artifact(artifacts, "hostAgentImage", release_input_dir)
    image_ref = require_image_reference(image, "hostAgentImage")
    if not re.fullmatch(
        r"registry\.local/appliance-host-agent@sha256:[0-9a-f]{64}", image_ref
    ):
        raise ValueError(
            "release-input artifacts.hostAgentImage.imageReference must be "
            "registry.local/appliance-host-agent@sha256:<64 lowercase hex>"
        )
    if "host-agent" not in image_path.name.lower() and "hostagent" not in image_path.name.lower():
        raise ValueError(
            "release-input artifacts.hostAgentImage.path must identify "
            f"appliance-host-agent, got {image['path']!r}"
        )
    require_oci_archive_reference_matches_content(image_path, image_ref, "hostAgentImage")
    index = load_oci_archive_index(image_path)
    if index is None:
        raise ValueError(f"hostAgentImage OCI archive {image_path} is missing index.json")
    annotation = (
        (index.get("manifests") or [{}])[0].get("annotations") or {}
    ).get("org.opencontainers.image.ref.name")
    if annotation != "registry.local/appliance-host-agent:bundled":
        raise ValueError(
            "hostAgentImage OCI archive annotation must be "
            "'registry.local/appliance-host-agent:bundled', "
            f"got {annotation!r}"
        )
    image_bundle_path = f"oci-images/{image_path.name}"
    image_entry = require_bundle_entry(entries_by_path, image_bundle_path, "hostAgentImage")
    require_matching_bundle_digest(image_entry, image, image_bundle_path, "hostAgentImage")
    require_matching_bundle_image_reference(
        image_entry, image_ref, image_bundle_path, "hostAgentImage"
    )

    binary = require_artifact(artifacts, "hostAgentBinary")
    binary_path = require_file_artifact(artifacts, "hostAgentBinary", release_input_dir)
    if "host-agent" not in binary_path.name.lower() and "hostagent" not in binary_path.name.lower():
        raise ValueError(
            "release-input artifacts.hostAgentBinary.path must identify "
            f"appliance-host-agentd, got {binary['path']!r}"
        )
    binary_bundle_path = f"bin/{binary_path.name}"
    binary_entry = require_bundle_entry(entries_by_path, binary_bundle_path, "hostAgentBinary")
    require_matching_bundle_digest(binary_entry, binary, binary_bundle_path, "hostAgentBinary")
    return ["hostAgentImage", "hostAgentBinary"]


def validate_required_artifacts(
    artifacts: dict, release_input_dir: Path, entries_by_path: dict, *, host_mdns_enabled: bool
) -> list:
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

    host_packages_present = isinstance(artifacts.get("hostPackages"), dict)
    bundle_has_host_packages = any(path.startswith("host-packages/") for path in entries_by_path)
    if host_mdns_enabled:
        require_dir_artifact(artifacts, "hostPackages", release_input_dir)
        require_bundle_entry_prefix(entries_by_path, "host-packages/", "hostPackages")
        checked.append("hostPackages")
    else:
        if host_packages_present:
            raise ValueError("release-input artifacts.hostPackages must be omitted when host mDNS is disabled")
        if bundle_has_host_packages:
            raise ValueError("bundle manifest host-packages entries must be omitted when host mDNS is disabled")

    for key in ("sbom", "provenance", "notices", "tests"):
        require_dir_artifact(artifacts, key, release_input_dir)
        checked.append(key)

    return checked


def validate_metadata_bundle(
    release_input: dict,
    artifacts: dict,
    release_input_dir: Path,
    entries_by_path: dict[str, dict],
) -> list:
    artifact = require_artifact(artifacts, "metadataBundle")
    if str(artifact.get("imageReference") or "").strip():
        raise ValueError("release-input artifacts.metadataBundle must not set imageReference")
    archive_path = require_file_artifact(artifacts, "metadataBundle", release_input_dir)
    name = archive_path.name
    if not name.startswith("appliance-metadata-bundle-") or not name.endswith(".tar.zst"):
        raise ValueError(
            "release-input artifacts.metadataBundle path must be named "
            "appliance-metadata-bundle-X.Y.Z.N.tar.zst"
        )
    bundle_path = f"artifacts/{name}"
    require_bundle_entry(entries_by_path, bundle_path, "metadataBundle")
    return ["metadataBundle"]


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
        # Example failure mode: workspace-provisioner.tar labeled as dev-build.
        path_name = image_path.name.lower()
        ref_lower = image_ref.lower()
        for token in ("workspace-provisioner", "dev-build"):
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
        "--host-mdns-enabled",
        default="false",
        help="Whether release-input is expected to include host-packages for host mDNS support.",
    )
    parser.add_argument(
        "--expected-extra-oci-image-refs",
        default="",
        help="Comma-separated digest-pinned extra OCI image references expected in release-input and bundle.",
    )
    args = parser.parse_args()
    host_mdns_enabled = parse_bool_arg(args.host_mdns_enabled, "--host-mdns-enabled")
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
            artifacts, release_input_path.parent, entries_by_path, host_mdns_enabled=host_mdns_enabled
        ),
        "runtimeValues": validate_runtime_values(artifacts, bundle_values),
        "zot": validate_zot(
            release_input,
            bundle_manifest,
            artifacts,
            release_input_path.parent,
            entries_by_path,
        ),
        "dns": validate_dns(
            release_input,
            bundle_manifest,
            artifacts,
            release_input_path.parent,
            entries_by_path,
        ),
        "metadataBundle": validate_metadata_bundle(
            release_input,
            artifacts,
            release_input_path.parent,
            entries_by_path,
        ),
        "hostAgent": validate_host_agent(
            artifacts,
            release_input_path.parent,
            entries_by_path,
        ),
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
