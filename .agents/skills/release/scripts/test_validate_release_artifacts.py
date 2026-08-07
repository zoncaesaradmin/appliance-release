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
    args = list(extra_args)
    return subprocess.run(
        [
            "python3",
            str(VALIDATOR),
            "--release-input-root",
            str(tmp / "release-input"),
            "--bundle-root",
            str(tmp / "bundle"),
            *args,
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def populate_positive_case(tmp: Path, *, include_host_packages: bool = True) -> None:
    artifact_server_digest = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    dns_digest = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    host_agent_digest = "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    inference_digest = "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    write(tmp / "release-input" / "images" / "control-plane.tar", "control")
    write(tmp / "release-input" / "images" / "appliance-ui.tar", "ui")
    write(tmp / "release-input" / "chart" / "appliance-chart-1.0.0.tgz", "appliance chart")
    write(tmp / "release-input" / "schemas" / "configuration.schema.json", "{}")
    write(tmp / "release-input" / "compatibility.json", "{}")
    write(tmp / "release-input" / "checksums.txt", "checksums")
    if include_host_packages:
        write(tmp / "release-input" / "host-packages" / "ubuntu" / "24.04" / "amd64" / "avahi-daemon.deb", "deb")
    write(tmp / "release-input" / "sbom" / "appliance.spdx.json", "{}")
    write(tmp / "release-input" / "provenance" / "appliance.provenance.json", "{}")
    write(tmp / "release-input" / "notices" / "THIRD-PARTY-NOTICES.txt", "notice")
    write(tmp / "release-input" / "tests" / "conformance.txt", "tests")
    write(tmp / "release-input" / "chart" / "argo-workflows-1.0.0.tgz", "chart")
    write(tmp / "release-input" / "crds" / "workflows.yaml", "crd")
    write(tmp / "release-input" / "images" / "workflow-controller.tar", "controller")
    write(tmp / "release-input" / "images" / "workflow-executor.tar", "executor")
    write(tmp / "release-input" / "images" / "buildah.tar", "buildah")
    write(tmp / "release-input" / "chart" / "appliance-registry-2.1.11.tgz", "artifact server chart")
    write_mismatched_oci_archive(
        tmp / "release-input" / "images" / "artifact-server-image.tar",
        "registry.local/artifact-server:bundled",
        artifact_server_digest,
    )
    write(tmp / "release-input" / "chart" / "appliance-dns-1.14.4.tgz", "coredns chart")
    write_mismatched_oci_archive(
        tmp / "release-input" / "images" / "coredns-image.tar",
        "registry.local/coredns:bundled",
        dns_digest,
    )
    write(tmp / "release-input" / "chart" / "appliance-inference-0.6.5.tgz", "inference chart")
    write_mismatched_oci_archive(
        tmp / "release-input" / "images" / "inference-runtime-image.tar",
        "registry.local/inference-runtime:bundled",
        inference_digest,
    )
    write_mismatched_oci_archive(
        tmp / "release-input" / "images" / "appliance-host-agent.tar",
        "registry.local/appliance-host-agent:bundled",
        host_agent_digest,
    )
    write(tmp / "release-input" / "bin" / "appliance-host-agentd", "host-agentd")
    write(tmp / "release-input" / "artifacts" / "appliance-metadata-bundle-1.0.0.0.tar.zst", "policy")
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
    "hostAgentImage": {"path": "images/appliance-host-agent.tar", "digest": "sha256:host-agent-archive", "sizeBytes": 256, "imageReference": "registry.local/appliance-host-agent@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"},
    "hostAgentBinary": {"path": "bin/appliance-host-agentd", "digest": "sha256:host-agentd", "sizeBytes": 11},
    "applianceChart": {"path": "chart/appliance-chart-1.0.0.tgz", "digest": "sha256:appliance-chart", "sizeBytes": 15},
    "artifactServerImage": {"path": "images/artifact-server-image.tar", "digest": "sha256:artifact-server-archive", "sizeBytes": 1024, "imageReference": "registry.local/artifact-server@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
    "artifactServerChart": {"path": "chart/appliance-registry-2.1.11.tgz", "digest": "sha256:artifact-server-chart", "sizeBytes": 9},
    "dnsImage": {"path": "images/coredns-image.tar", "digest": "sha256:dns-archive", "sizeBytes": 512, "imageReference": "registry.local/coredns@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},
    "dnsChart": {"path": "chart/appliance-dns-1.14.4.tgz", "digest": "sha256:dns-chart", "sizeBytes": 11},
    "inferenceRuntimeImage": {"path": "images/inference-runtime-image.tar", "digest": "sha256:inference-archive", "sizeBytes": 512, "imageReference": "registry.local/inference-runtime@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"},
    "inferenceChart": {"path": "chart/appliance-inference-0.6.5.tgz", "digest": "sha256:inference-chart", "sizeBytes": 15},
    "metadataBundle": {"path": "artifacts/appliance-metadata-bundle-1.0.0.0.tar.zst", "digest": "sha256:policy", "sizeBytes": 6},
    "configurationSchema": {"path": "schemas/configuration.schema.json", "digest": "sha256:configuration", "sizeBytes": 2},
    "compatibility": {"path": "compatibility.json", "digest": "sha256:compatibility", "sizeBytes": 2},
    "checksums": {"path": "checksums.txt", "digest": "sha256:checksums", "sizeBytes": 9},
    "sbom": {"path": "sbom", "manifestDigest": "sha256:sbom"},
    "provenance": {"path": "provenance", "manifestDigest": "sha256:provenance"},
    "notices": {"path": "notices", "manifestDigest": "sha256:notices"},
    "tests": {"path": "tests", "manifestDigest": "sha256:tests"},
    "workflowsChart": {"path": "chart/argo-workflows-1.0.0.tgz", "digest": "sha256:chart", "sizeBytes": 5},
    "workflowsCRDs": {"path": "crds", "manifestDigest": "sha256:crds"},
    "workflowControllerImage": {"path": "images/workflow-controller.tar", "digest": "sha256:controller", "sizeBytes": 10, "imageReference": "quay.io/argoproj/workflow-controller:v3.5.10"},
    "workflowExecutorImage": {"path": "images/workflow-executor.tar", "digest": "sha256:executor", "sizeBytes": 8, "imageReference": "quay.io/argoproj/argoexec:v3.5.10"},
    "extraOCIImages": [
      {"path": "images/buildah.tar", "digest": "sha256:buildah", "sizeBytes": 6, "imageReference": "registry.local/buildah@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
    ]
  },
  "compatibility": {"k3sVersion": "v1.30.4+k3s1", "chartVersion": "1.0.0", "artifactServerVersion": "2.1.11", "dnsVersion": "1.14.4", "inferenceVersion": "0.6.5"}
}
""".lstrip(),
    )
    if include_host_packages:
        release_input_path = tmp / "release-input" / "release-input.json"
        release_input = json.loads(release_input_path.read_text(encoding="utf-8"))
        release_input["artifacts"]["hostPackages"] = {
            "path": "host-packages",
            "manifestDigest": "sha256:host-packages",
        }
        release_input_path.write_text(json.dumps(release_input), encoding="utf-8")
    write(
        tmp / "bundle" / "release-manifest.json",
        """
{
  "compatibility": {"k3sVersion": "v1.30.4+k3s1", "chartVersion": "1.0.0", "artifactServerVersion": "2.1.11", "dnsVersion": "1.14.4", "inferenceVersion": "0.6.5"},
  "entries": [
    {"targetPath": "oci-images/control-plane.tar", "digest": "sha256:control", "sizeBytes": 7, "imageReference": "internal/control-plane:1.0.0"},
    {"targetPath": "oci-images/appliance-ui.tar", "digest": "sha256:ui", "sizeBytes": 2, "imageReference": "internal/appliance-ui:1.0.0"},
    {"targetPath": "oci-images/appliance-host-agent.tar", "digest": "sha256:host-agent-archive", "sizeBytes": 256, "imageReference": "registry.local/appliance-host-agent@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"},
    {"targetPath": "bin/appliance-host-agentd", "digest": "sha256:host-agentd", "sizeBytes": 11},
    {"targetPath": "charts/appliance-chart-1.0.0.tgz", "digest": "sha256:appliance-chart", "sizeBytes": 15},
    {"targetPath": "oci-images/artifact-server-image.tar", "digest": "sha256:artifact-server-archive", "sizeBytes": 1024, "imageReference": "registry.local/artifact-server@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
    {"targetPath": "charts/appliance-registry-2.1.11.tgz", "digest": "sha256:artifact-server-chart", "sizeBytes": 9},
    {"targetPath": "oci-images/coredns-image.tar", "digest": "sha256:dns-archive", "sizeBytes": 512, "imageReference": "registry.local/coredns@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},
    {"targetPath": "charts/appliance-dns-1.14.4.tgz", "digest": "sha256:dns-chart", "sizeBytes": 11},
    {"targetPath": "oci-images/inference-runtime-image.tar", "digest": "sha256:inference-archive", "sizeBytes": 512, "imageReference": "registry.local/inference-runtime@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"},
    {"targetPath": "charts/appliance-inference-0.6.5.tgz", "digest": "sha256:inference-chart", "sizeBytes": 15},
    {"targetPath": "artifacts/appliance-metadata-bundle-1.0.0.0.tar.zst", "digest": "sha256:policy", "sizeBytes": 6},
    {"targetPath": "configuration/values.yaml", "digest": "sha256:values", "sizeBytes": 200},
    {"targetPath": "charts/argo-workflows-1.0.0.tgz", "digest": "sha256:chart", "sizeBytes": 5},
    {"targetPath": "kubernetes/crds/crds/workflows.yaml", "digest": "sha256:crd", "sizeBytes": 3},
    {"targetPath": "oci-images/workflow-controller.tar", "digest": "sha256:controller", "sizeBytes": 10, "imageReference": "quay.io/argoproj/workflow-controller:v3.5.10"},
    {"targetPath": "oci-images/workflow-executor.tar", "digest": "sha256:executor", "sizeBytes": 8, "imageReference": "quay.io/argoproj/argoexec:v3.5.10"},
    {"targetPath": "oci-images/buildah.tar", "digest": "sha256:buildah", "sizeBytes": 6, "imageReference": "registry.local/buildah@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
  ]
}
""".lstrip(),
    )
    if include_host_packages:
        manifest_path = tmp / "bundle" / "release-manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["entries"].insert(
            4,
            {
                "targetPath": "host-packages/ubuntu/24.04/amd64/avahi-daemon.deb",
                "digest": "sha256:host-package",
                "sizeBytes": 3,
            },
        )
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")


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
        result = run_validator(tmp, "--require-workflows")
        if result.returncode != 0:
            raise AssertionError(result.stderr)


def test_rejects_missing_host_packages_when_flags_false() -> None:
    """Complete product always requires host-packages regardless of install flags."""
    with tempfile.TemporaryDirectory(prefix="release-artifact-validator-") as tmp_dir:
        tmp = Path(tmp_dir)
        populate_positive_case(tmp, include_host_packages=False)
        result = run_validator(tmp, "--require-workflows")
        if result.returncode == 0:
            raise AssertionError("missing host-packages were accepted when install flags are false")
        if "hostPackages" not in result.stderr and "host-packages" not in result.stderr.lower():
            raise AssertionError(result.stderr)


def test_positive_case_with_nested_bundle_root() -> None:
    with tempfile.TemporaryDirectory(prefix="release-artifact-validator-") as tmp_dir:
        tmp = Path(tmp_dir)
        populate_positive_case_with_nested_bundle(tmp)
        result = run_validator(tmp, "--require-workflows")
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
            result = run_validator(tmp, "--require-workflows")
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


def test_rejects_missing_host_packages_bundle_entry() -> None:
    with tempfile.TemporaryDirectory(prefix="release-artifact-validator-") as tmp_dir:
        tmp = Path(tmp_dir)
        populate_positive_case(tmp)
        manifest_path = tmp / "bundle" / "release-manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["entries"] = [
            entry
            for entry in manifest["entries"]
            if not entry["targetPath"].startswith("host-packages/")
        ]
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        result = run_validator(tmp)
        if result.returncode == 0:
            raise AssertionError("missing host-packages bundle entries were accepted")
        if "hostPackages" not in result.stderr:
            raise AssertionError(result.stderr)


def test_accepts_host_packages_when_install_host_flags_false() -> None:
    """Install host flags do not affect package layout validation."""
    with tempfile.TemporaryDirectory(prefix="release-artifact-validator-") as tmp_dir:
        tmp = Path(tmp_dir)
        populate_positive_case(tmp, include_host_packages=True)
        result = run_validator(tmp, "--require-workflows")
        if result.returncode != 0:
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
        # Keep the wrong dev-build-style ref to simulate the pairing bug.
        release_input["artifacts"]["extraOCIImages"][0]["imageReference"] = (
            "registry.local/dev-build@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
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


def write_mismatched_oci_archive(
    path: Path,
    annotated_ref: str,
    content_digest: str,
    *,
    member_prefix: str = "",
) -> None:
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
        info = tarfile.TarInfo(name=f"{member_prefix}index.json")
        info.size = len(payload)
        tar.addfile(info, io.BytesIO(payload))


def test_accepts_dot_slash_prefixed_dns_oci_archive() -> None:
    """GNU tar packing with '.' can emit ./index.json; validators must accept it."""
    with tempfile.TemporaryDirectory(prefix="release-artifact-validator-") as tmp_dir:
        tmp = Path(tmp_dir)
        populate_positive_case(tmp)
        archive_path = tmp / "release-input" / "images" / "coredns-image.tar"
        write_mismatched_oci_archive(
            archive_path,
            "registry.local/coredns:bundled",
            "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            member_prefix="./",
        )
        release_input_path = tmp / "release-input" / "release-input.json"
        release_input = json.loads(release_input_path.read_text(encoding="utf-8"))
        release_input["artifacts"]["dnsImage"]["sizeBytes"] = archive_path.stat().st_size
        release_input_path.write_text(json.dumps(release_input), encoding="utf-8")
        result = run_validator(tmp)
        if result.returncode != 0:
            raise AssertionError(result.stderr or result.stdout)


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


def test_rejects_artifact_server_annotation_and_version_mismatch() -> None:
    with tempfile.TemporaryDirectory(prefix="release-artifact-validator-") as tmp_dir:
        tmp = Path(tmp_dir)
        populate_positive_case(tmp)
        write_mismatched_oci_archive(
            tmp / "release-input" / "images" / "artifact-server-image.tar",
            "registry.local/artifact-server:wrong",
            "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        )
        result = run_validator(tmp)
        if result.returncode == 0 or "annotation must be" not in result.stderr:
            raise AssertionError(result.stderr or "wrong artifact-server annotation accepted")

        populate_positive_case(tmp)
        manifest_path = tmp / "bundle" / "release-manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["compatibility"]["artifactServerVersion"] = "2.1.12"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        result = run_validator(tmp)
        if result.returncode == 0 or "artifactServerVersion mismatch" not in result.stderr:
            raise AssertionError(result.stderr or "wrong artifact-server version accepted")


def test_rejects_dns_annotation_and_version_mismatch() -> None:
    with tempfile.TemporaryDirectory(prefix="release-artifact-validator-") as tmp_dir:
        tmp = Path(tmp_dir)
        populate_positive_case(tmp)
        write_mismatched_oci_archive(
            tmp / "release-input" / "images" / "coredns-image.tar",
            "registry.local/coredns:wrong",
            "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        )
        result = run_validator(tmp)
        if result.returncode == 0 or "annotation must be" not in result.stderr:
            raise AssertionError(result.stderr or "wrong dns annotation accepted")

        populate_positive_case(tmp)
        manifest_path = tmp / "bundle" / "release-manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["compatibility"]["dnsVersion"] = "1.14.5"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        result = run_validator(tmp)
        if result.returncode == 0 or "dnsVersion mismatch" not in result.stderr:
            raise AssertionError(result.stderr or "wrong dns version accepted")


def test_rejects_inference_annotation_and_version_mismatch() -> None:
    with tempfile.TemporaryDirectory(prefix="release-artifact-validator-") as tmp_dir:
        tmp = Path(tmp_dir)
        populate_positive_case(tmp)
        write_mismatched_oci_archive(
            tmp / "release-input" / "images" / "inference-runtime-image.tar",
            "registry.local/inference-runtime:wrong",
            "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        )
        result = run_validator(tmp)
        if result.returncode == 0 or "annotation must be" not in result.stderr:
            raise AssertionError(result.stderr or "wrong inference annotation accepted")

        populate_positive_case(tmp)
        manifest_path = tmp / "bundle" / "release-manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["compatibility"]["inferenceVersion"] = "0.6.6"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        result = run_validator(tmp)
        if result.returncode == 0 or "inferenceVersion mismatch" not in result.stderr:
            raise AssertionError(result.stderr or "wrong inference version accepted")


def test_rejects_legacy_zot_image_path_name() -> None:
    """Hard-cut rename: plain "zot" basenames are no longer accepted."""
    with tempfile.TemporaryDirectory(prefix="release-artifact-validator-") as tmp_dir:
        tmp = Path(tmp_dir)
        populate_positive_case(tmp)
        old = tmp / "release-input" / "images" / "artifact-server-image.tar"
        new = tmp / "release-input" / "images" / "zot-image.tar"
        old.rename(new)
        release_input_path = tmp / "release-input" / "release-input.json"
        release_input = json.loads(release_input_path.read_text(encoding="utf-8"))
        release_input["artifacts"]["artifactServerImage"]["path"] = "images/zot-image.tar"
        release_input_path.write_text(json.dumps(release_input), encoding="utf-8")
        manifest_path = tmp / "bundle" / "release-manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        for entry in manifest["entries"]:
            if entry.get("targetPath") == "oci-images/artifact-server-image.tar":
                entry["targetPath"] = "oci-images/zot-image.tar"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        result = run_validator(tmp)
        if result.returncode == 0 or "must identify Artifact Server" not in result.stderr:
            raise AssertionError(result.stderr or "legacy zot-only basename was accepted")


def test_rejects_unidentified_artifact_server_image_path() -> None:
    with tempfile.TemporaryDirectory(prefix="release-artifact-validator-") as tmp_dir:
        tmp = Path(tmp_dir)
        populate_positive_case(tmp)
        old = tmp / "release-input" / "images" / "artifact-server-image.tar"
        new = tmp / "release-input" / "images" / "registry-image.tar"
        old.rename(new)
        release_input_path = tmp / "release-input" / "release-input.json"
        release_input = json.loads(release_input_path.read_text(encoding="utf-8"))
        release_input["artifacts"]["artifactServerImage"]["path"] = "images/registry-image.tar"
        release_input_path.write_text(json.dumps(release_input), encoding="utf-8")
        manifest_path = tmp / "bundle" / "release-manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        for entry in manifest["entries"]:
            if entry.get("targetPath") == "oci-images/artifact-server-image.tar":
                entry["targetPath"] = "oci-images/registry-image.tar"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        result = run_validator(tmp)
        if result.returncode == 0 or "must identify Artifact Server" not in result.stderr:
            raise AssertionError(result.stderr or "unidentified Artifact Server path accepted")


def main() -> None:
    test_positive_case()
    test_rejects_missing_host_packages_when_flags_false()
    test_positive_case_with_nested_bundle_root()
    test_allows_empty_directory_artifacts()
    test_rejects_tag_only_extra_oci_image()
    test_rejects_placeholder_extra_oci_image_digest()
    test_rejects_missing_expected_extra_oci_image_ref()
    test_allows_expected_extra_oci_image_ref_with_stale_advisory_digest()
    test_rejects_workspace_provisioner_path_ref_mismatch()
    test_rejects_oci_archive_annotation_digest_mismatch()
    test_accepts_dot_slash_prefixed_dns_oci_archive()
    test_rejects_artifact_server_annotation_and_version_mismatch()
    test_rejects_dns_annotation_and_version_mismatch()
    test_rejects_inference_annotation_and_version_mismatch()
    test_rejects_legacy_zot_image_path_name()
    test_rejects_unidentified_artifact_server_image_path()
    test_rejects_missing_ui_bundle_entry()
    test_rejects_missing_host_packages_bundle_entry()
    test_accepts_host_packages_when_install_host_flags_false()
    test_rejects_mismatched_ui_bundle_image_reference()
    test_rejects_mismatched_ui_values_image_reference()
    print("validate-release-artifacts tests passed")


if __name__ == "__main__":
    main()
