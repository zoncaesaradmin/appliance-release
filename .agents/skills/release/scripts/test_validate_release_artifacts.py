#!/usr/bin/env python3
"""Local tests for validate-release-artifacts.py."""

import subprocess
import tempfile
from pathlib import Path
import json


ROOT = Path(__file__).resolve().parents[4]
VALIDATOR = ROOT / ".agents" / "skills" / "release" / "scripts" / "validate-release-artifacts.py"


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def run_validator(tmp: Path, *extra_args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [
            "python3",
            str(VALIDATOR),
            "--release-input-root",
            str(tmp / "release-input"),
            "--bundle-root",
            str(tmp / "bundle"),
            *extra_args,
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def populate_positive_case(tmp: Path) -> None:
    zot_digest = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    write(tmp / "release-input" / "images" / "control-plane.tar", "control")
    write(tmp / "release-input" / "images" / "appliance-ui.tar", "ui")
    write(tmp / "release-input" / "chart" / "appliance-chart-1.0.0.tgz", "appliance chart")
    write(tmp / "release-input" / "schemas" / "configuration.schema.json", "{}")
    write(tmp / "release-input" / "compatibility.json", "{}")
    write(tmp / "release-input" / "checksums.txt", "checksums")
    write(tmp / "release-input" / "sbom" / "appliance.spdx.json", "{}")
    write(tmp / "release-input" / "provenance" / "appliance.provenance.json", "{}")
    write(tmp / "release-input" / "notices" / "THIRD-PARTY-NOTICES.txt", "notice")
    write(tmp / "release-input" / "tests" / "conformance.txt", "tests")
    write(tmp / "release-input" / "chart" / "argo-workflows-1.0.0.tgz", "chart")
    write(tmp / "release-input" / "crds" / "workflows.yaml", "crd")
    write(tmp / "release-input" / "images" / "argo-controller.tar", "controller")
    write(tmp / "release-input" / "images" / "argo-executor.tar", "executor")
    write(tmp / "release-input" / "images" / "buildah.tar", "buildah")
    write(tmp / "release-input" / "chart" / "appliance-registry-2.1.11.tgz", "zot chart")
    write_mismatched_oci_archive(
        tmp / "release-input" / "images" / "zot-image.tar",
        "registry.local/zot:bundled",
        zot_digest,
    )
    write(
        tmp / "bundle" / "configuration" / "values.yaml",
        """
image:
  repository: internal/control-plane
  tag: "1.0.0"
  digest: ""

ui:
  enabled: true
  image:
    repository: internal/appliance-ui
    tag: "1.0.0"
    digest: ""
  service:
    port: 8080

ingress:
  enabled: true
  entryPoints:
    - websecure
""".lstrip(),
    )
    write(
        tmp / "release-input" / "release-input.json",
        """
{
  "artifacts": {
    "controlPlaneImage": {"path": "images/control-plane.tar", "digest": "sha256:control", "sizeBytes": 7, "imageReference": "internal/control-plane:1.0.0"},
    "uiImage": {"path": "images/appliance-ui.tar", "digest": "sha256:ui", "sizeBytes": 2, "imageReference": "internal/appliance-ui:1.0.0"},
    "applianceChart": {"path": "chart/appliance-chart-1.0.0.tgz", "digest": "sha256:appliance-chart", "sizeBytes": 15},
    "zotImage": {"path": "images/zot-image.tar", "digest": "sha256:zot-archive", "sizeBytes": 1024, "imageReference": "registry.local/zot@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
    "zotChart": {"path": "chart/appliance-registry-2.1.11.tgz", "digest": "sha256:zot-chart", "sizeBytes": 9},
    "configurationSchema": {"path": "schemas/configuration.schema.json", "digest": "sha256:configuration", "sizeBytes": 2},
    "compatibility": {"path": "compatibility.json", "digest": "sha256:compatibility", "sizeBytes": 2},
    "checksums": {"path": "checksums.txt", "digest": "sha256:checksums", "sizeBytes": 9},
    "sbom": {"path": "sbom", "manifestDigest": "sha256:sbom"},
    "provenance": {"path": "provenance", "manifestDigest": "sha256:provenance"},
    "notices": {"path": "notices", "manifestDigest": "sha256:notices"},
    "tests": {"path": "tests", "manifestDigest": "sha256:tests"},
    "argoWorkflowsChart": {"path": "chart/argo-workflows-1.0.0.tgz", "digest": "sha256:chart", "sizeBytes": 5},
    "argoCRDs": {"path": "crds", "manifestDigest": "sha256:crds"},
    "argoControllerImage": {"path": "images/argo-controller.tar", "digest": "sha256:controller", "sizeBytes": 10, "imageReference": "quay.io/argoproj/workflow-controller:v3.5.10"},
    "argoExecutorImage": {"path": "images/argo-executor.tar", "digest": "sha256:executor", "sizeBytes": 8, "imageReference": "quay.io/argoproj/argoexec:v3.5.10"},
    "extraOCIImages": [
      {"path": "images/buildah.tar", "digest": "sha256:buildah", "sizeBytes": 6, "imageReference": "registry.local/buildah@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
    ]
  },
  "compatibility": {"k3sVersion": "v1.30.4+k3s1", "chartVersion": "1.0.0", "zotVersion": "2.1.11"}
}
""".lstrip(),
    )
    write(
        tmp / "bundle" / "release-manifest.json",
        """
{
  "compatibility": {"k3sVersion": "v1.30.4+k3s1", "chartVersion": "1.0.0", "zotVersion": "2.1.11"},
  "entries": [
    {"targetPath": "oci-images/control-plane.tar", "digest": "sha256:control", "sizeBytes": 7, "imageReference": "internal/control-plane:1.0.0"},
    {"targetPath": "oci-images/appliance-ui.tar", "digest": "sha256:ui", "sizeBytes": 2, "imageReference": "internal/appliance-ui:1.0.0"},
    {"targetPath": "charts/appliance-chart-1.0.0.tgz", "digest": "sha256:appliance-chart", "sizeBytes": 15},
    {"targetPath": "oci-images/zot-image.tar", "digest": "sha256:zot-archive", "sizeBytes": 1024, "imageReference": "registry.local/zot@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
    {"targetPath": "charts/appliance-registry-2.1.11.tgz", "digest": "sha256:zot-chart", "sizeBytes": 9},
    {"targetPath": "configuration/values.yaml", "digest": "sha256:values", "sizeBytes": 200},
    {"targetPath": "charts/argo-workflows-1.0.0.tgz", "digest": "sha256:chart", "sizeBytes": 5},
    {"targetPath": "kubernetes/crds/crds/workflows.yaml", "digest": "sha256:crd", "sizeBytes": 3},
    {"targetPath": "oci-images/argo-controller.tar", "digest": "sha256:controller", "sizeBytes": 10, "imageReference": "quay.io/argoproj/workflow-controller:v3.5.10"},
    {"targetPath": "oci-images/argo-executor.tar", "digest": "sha256:executor", "sizeBytes": 8, "imageReference": "quay.io/argoproj/argoexec:v3.5.10"},
    {"targetPath": "oci-images/buildah.tar", "digest": "sha256:buildah", "sizeBytes": 6, "imageReference": "registry.local/buildah@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
  ]
}
""".lstrip(),
    )


def populate_positive_case_with_nested_bundle(tmp: Path) -> None:
    populate_positive_case(tmp)
    nested_root = tmp / "bundle" / "appliance-0.1.0-bundle"
    nested_root.mkdir(parents=True, exist_ok=True)
    (tmp / "bundle" / "configuration").rename(nested_root / "configuration")
    (tmp / "bundle" / "release-manifest.json").rename(nested_root / "release-manifest.json")


def test_positive_case() -> None:
    with tempfile.TemporaryDirectory(prefix="release-artifact-validator-") as tmp_dir:
        tmp = Path(tmp_dir)
        populate_positive_case(tmp)
        result = run_validator(tmp, "--require-argo")
        if result.returncode != 0:
            raise AssertionError(result.stderr)


def test_positive_case_with_nested_bundle_root() -> None:
    with tempfile.TemporaryDirectory(prefix="release-artifact-validator-") as tmp_dir:
        tmp = Path(tmp_dir)
        populate_positive_case_with_nested_bundle(tmp)
        result = run_validator(tmp, "--require-argo")
        if result.returncode != 0:
            raise AssertionError(result.stderr)


def test_allows_empty_directory_artifacts() -> None:
    with tempfile.TemporaryDirectory(prefix="release-artifact-validator-") as tmp_dir:
        tmp = Path(tmp_dir)
        populate_positive_case(tmp)
        for name in ("sbom", "provenance", "notices", "tests"):
            directory = tmp / "release-input" / name
            for child in list(directory.rglob("*")):
                if child.is_file():
                    child.unlink()
            result = run_validator(tmp, "--require-argo")
        if result.returncode != 0:
            raise AssertionError(result.stderr)


def test_rejects_tag_only_extra_oci_image() -> None:
    with tempfile.TemporaryDirectory(prefix="release-artifact-validator-") as tmp_dir:
        tmp = Path(tmp_dir)
        populate_positive_case(tmp)
        release_input_path = tmp / "release-input" / "release-input.json"
        release_input = json.loads(release_input_path.read_text(encoding="utf-8"))
        release_input["artifacts"]["extraOCIImages"][0]["imageReference"] = "registry.local/buildah:latest"
        release_input_path.write_text(json.dumps(release_input), encoding="utf-8")
        result = run_validator(tmp)
        if result.returncode == 0:
            raise AssertionError("tag-only extraOCIImages imageReference was accepted")
        if "must be digest-pinned" not in result.stderr:
            raise AssertionError(result.stderr)


def test_rejects_placeholder_extra_oci_image_digest() -> None:
    with tempfile.TemporaryDirectory(prefix="release-artifact-validator-") as tmp_dir:
        tmp = Path(tmp_dir)
        populate_positive_case(tmp)
        release_input_path = tmp / "release-input" / "release-input.json"
        release_input = json.loads(release_input_path.read_text(encoding="utf-8"))
        release_input["artifacts"]["extraOCIImages"][0]["imageReference"] = "registry.local/buildah@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        release_input_path.write_text(json.dumps(release_input), encoding="utf-8")
        result = run_validator(tmp)
        if result.returncode == 0:
            raise AssertionError("placeholder extraOCIImages imageReference was accepted")
        if "must be digest-pinned" not in result.stderr:
            raise AssertionError(result.stderr)


def test_rejects_missing_expected_extra_oci_image_ref() -> None:
    with tempfile.TemporaryDirectory(prefix="release-artifact-validator-") as tmp_dir:
        tmp = Path(tmp_dir)
        populate_positive_case(tmp)
        result = run_validator(
            tmp,
            "--expected-extra-oci-image-refs",
            "registry.local/buildah@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,registry.local/missing@sha256:def456",
        )
        if result.returncode == 0:
            raise AssertionError("missing expected extra OCI image ref was accepted")
        if "missing expected image refs" not in result.stderr:
            raise AssertionError(result.stderr)


def test_allows_expected_extra_oci_image_ref_with_stale_advisory_digest() -> None:
    """Config pins may lag the derived platform digest; match by repository name."""
    with tempfile.TemporaryDirectory(prefix="release-artifact-validator-") as tmp_dir:
        tmp = Path(tmp_dir)
        populate_positive_case(tmp)
        result = run_validator(
            tmp,
            "--expected-extra-oci-image-refs",
            "registry.local/buildah@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        )
        if result.returncode != 0:
            raise AssertionError(result.stderr)


def test_rejects_missing_ui_bundle_entry() -> None:
    with tempfile.TemporaryDirectory(prefix="release-artifact-validator-") as tmp_dir:
        tmp = Path(tmp_dir)
        populate_positive_case(tmp)
        manifest_path = tmp / "bundle" / "release-manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["entries"] = [
            entry for entry in manifest["entries"] if entry["targetPath"] != "oci-images/appliance-ui.tar"
        ]
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        result = run_validator(tmp)
        if result.returncode == 0:
            raise AssertionError("missing UI image bundle entry was accepted")
        if "uiImage" not in result.stderr:
            raise AssertionError(result.stderr)


def test_rejects_mismatched_ui_bundle_image_reference() -> None:
    with tempfile.TemporaryDirectory(prefix="release-artifact-validator-") as tmp_dir:
        tmp = Path(tmp_dir)
        populate_positive_case(tmp)
        manifest_path = tmp / "bundle" / "release-manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        for entry in manifest["entries"]:
            if entry["targetPath"] == "oci-images/appliance-ui.tar":
                entry["imageReference"] = "internal/appliance-ui:wrong"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        result = run_validator(tmp)
        if result.returncode == 0:
            raise AssertionError("mismatched UI imageReference was accepted")
        if "imageReference mismatch" not in result.stderr or "uiImage" not in result.stderr:
            raise AssertionError(result.stderr)


def test_rejects_mismatched_ui_values_image_reference() -> None:
    with tempfile.TemporaryDirectory(prefix="release-artifact-validator-") as tmp_dir:
        tmp = Path(tmp_dir)
        populate_positive_case(tmp)
        values_path = tmp / "bundle" / "configuration" / "values.yaml"
        values_path.write_text(
            values_path.read_text(encoding="utf-8").replace(
                "repository: internal/appliance-ui", "repository: internal/appliance-ui-wrong"
            ),
            encoding="utf-8",
        )
        result = run_validator(tmp)
        if result.returncode == 0:
            raise AssertionError("mismatched UI values image reference was accepted")
        if "bundle values ui.image imageReference mismatch" not in result.stderr:
            raise AssertionError(result.stderr)


def test_rejects_workspace_provisioner_path_ref_mismatch() -> None:
    with tempfile.TemporaryDirectory(prefix="release-artifact-validator-") as tmp_dir:
        tmp = Path(tmp_dir)
        populate_positive_case(tmp)
        old_path = tmp / "release-input" / "images" / "buildah.tar"
        new_path = tmp / "release-input" / "images" / "workspace-provisioner-image.tar"
        old_path.rename(new_path)
        release_input_path = tmp / "release-input" / "release-input.json"
        release_input = json.loads(release_input_path.read_text(encoding="utf-8"))
        release_input["artifacts"]["extraOCIImages"][0]["path"] = "images/workspace-provisioner-image.tar"
        # Keep the wrong automation-dev-style ref to simulate the pairing bug.
        release_input["artifacts"]["extraOCIImages"][0]["imageReference"] = (
            "registry.local/automation-dev@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        )
        release_input_path.write_text(json.dumps(release_input), encoding="utf-8")
        manifest_path = tmp / "bundle" / "release-manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        for entry in manifest["entries"]:
            if entry.get("targetPath") == "oci-images/buildah.tar":
                entry["targetPath"] = "oci-images/workspace-provisioner-image.tar"
                entry["imageReference"] = release_input["artifacts"]["extraOCIImages"][0]["imageReference"]
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        result = run_validator(tmp)
        if result.returncode == 0:
            raise AssertionError("workspace-provisioner path/ref mismatch was accepted")
        if "implies imageReference containing 'workspace-provisioner'" not in result.stderr:
            raise AssertionError(result.stderr)


def write_mismatched_oci_archive(path: Path, annotated_ref: str, content_digest: str) -> None:
    import io
    import tarfile

    index = {
        "schemaVersion": 2,
        "mediaType": "application/vnd.oci.image.index.v1+json",
        "manifests": [
            {
                "mediaType": "application/vnd.oci.image.manifest.v1+json",
                "digest": content_digest,
                "size": 2,
                "annotations": {"org.opencontainers.image.ref.name": annotated_ref},
            }
        ],
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(path, "w") as tar:
        payload = json.dumps(index).encode("utf-8")
        info = tarfile.TarInfo(name="index.json")
        info.size = len(payload)
        tar.addfile(info, io.BytesIO(payload))


def test_rejects_oci_archive_annotation_digest_mismatch() -> None:
    with tempfile.TemporaryDirectory(prefix="release-artifact-validator-") as tmp_dir:
        tmp = Path(tmp_dir)
        populate_positive_case(tmp)
        content_digest = "sha256:5e1543841d987081a1e0e37305039b2bb9908592a4cddad95b4c4c49d07653a3"
        annotated_ref = (
            "registry.local/workspace-provisioner@"
            "sha256:77418e6e7c7f434c4a98eaff04ef16840cf03649c881c03948e3e213923e3136"
        )
        archive_path = tmp / "release-input" / "images" / "workspace-provisioner-image.tar"
        write_mismatched_oci_archive(archive_path, annotated_ref, content_digest)
        release_input_path = tmp / "release-input" / "release-input.json"
        release_input = json.loads(release_input_path.read_text(encoding="utf-8"))
        release_input["artifacts"]["extraOCIImages"] = [
            {
                "path": "images/workspace-provisioner-image.tar",
                "digest": "sha256:workspace-provisioner",
                "sizeBytes": archive_path.stat().st_size,
                "imageReference": annotated_ref,
            }
        ]
        release_input_path.write_text(json.dumps(release_input), encoding="utf-8")
        manifest_path = tmp / "bundle" / "release-manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["entries"] = [
            entry
            for entry in manifest["entries"]
            if entry.get("targetPath") != "oci-images/buildah.tar"
        ]
        manifest["entries"].append(
            {
                "targetPath": "oci-images/workspace-provisioner-image.tar",
                "digest": "sha256:workspace-provisioner",
                "sizeBytes": archive_path.stat().st_size,
                "imageReference": annotated_ref,
            }
        )
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        result = run_validator(tmp)
        if result.returncode == 0:
            raise AssertionError("OCI archive annotation/content digest mismatch was accepted")
        if "does not match imageReference digest" not in result.stderr and "annotation digest" not in result.stderr:
            raise AssertionError(result.stderr)


def test_rejects_zot_annotation_and_version_mismatch() -> None:
    with tempfile.TemporaryDirectory(prefix="release-artifact-validator-") as tmp_dir:
        tmp = Path(tmp_dir)
        populate_positive_case(tmp)
        write_mismatched_oci_archive(
            tmp / "release-input" / "images" / "zot-image.tar",
            "registry.local/zot:wrong",
            "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        )
        result = run_validator(tmp)
        if result.returncode == 0 or "annotation must be" not in result.stderr:
            raise AssertionError(result.stderr or "wrong zot annotation accepted")

        populate_positive_case(tmp)
        manifest_path = tmp / "bundle" / "release-manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["compatibility"]["zotVersion"] = "2.1.12"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        result = run_validator(tmp)
        if result.returncode == 0 or "zotVersion mismatch" not in result.stderr:
            raise AssertionError(result.stderr or "wrong zot version accepted")


def main() -> None:
    test_positive_case()
    test_positive_case_with_nested_bundle_root()
    test_allows_empty_directory_artifacts()
    test_rejects_tag_only_extra_oci_image()
    test_rejects_missing_expected_extra_oci_image_ref()
    test_allows_expected_extra_oci_image_ref_with_stale_advisory_digest()
    test_rejects_workspace_provisioner_path_ref_mismatch()
    test_rejects_oci_archive_annotation_digest_mismatch()
    test_rejects_zot_annotation_and_version_mismatch()
    test_rejects_missing_ui_bundle_entry()
    test_rejects_mismatched_ui_bundle_image_reference()
    test_rejects_mismatched_ui_values_image_reference()
    print("validate-release-artifacts tests passed")


if __name__ == "__main__":
    main()
