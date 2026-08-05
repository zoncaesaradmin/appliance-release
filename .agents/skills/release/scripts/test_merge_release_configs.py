#!/usr/bin/env python3
"""Local tests for merge-release-configs.py."""

import json
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[4]
MERGER = ROOT / ".agents" / "skills" / "release" / "scripts" / "merge-release-configs.py"


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def run_merge(mac: Path, build: Path, install: Path, out: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [
            "python3",
            str(MERGER),
            "--devhost-config",
            str(mac),
            "--build-publish-config",
            str(build),
            "--install-config",
            str(install),
            "--output",
            str(out),
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def minimal_parts(tmp: Path) -> tuple[Path, Path, Path]:
    mac = tmp / "mac.yaml"
    build = tmp / "build.yaml"
    install = tmp / "install.yaml"
    write(
        mac,
        """
build_host:
  alias: build@example
target_host:
  alias: target@example
  state_dir: /var/lib/zon/state
report:
  final_ok: true
""".lstrip(),
    )
    write(
        build,
        """
release_workspace:
  remote_repo_path: /tmp/ws
  remote_repo_source: https://example.com/r.git
  remote_repo_ref: main
  remote_export_dir: /tmp/export
release:
  version: 0.1.0
  publish_latest_alias: false
build_flow:
  skip: false
bundle_store:
  mode: static_http
  release_path_prefix: appliance
  base_url: http://example:9
""".lstrip(),
    )
    write(
        install,
        """
install:
  skip: false
  uninstall_first: true
  preserve_failed_state: false
  bootstrap_admin: false
  enable_default_license: false
  appliance_name: n
  dns_zone: z
  appliance_profile: core
  bundle_download_dir: /tmp/a
verification:
  status_command: true
client_verification:
  base_url: https://n.z
  username: admin
""".lstrip(),
    )
    return mac, build, install


def test_merges_disjoint_role_configs() -> None:
    with tempfile.TemporaryDirectory(prefix="merge-release-configs-") as tmp_dir:
        tmp = Path(tmp_dir)
        mac, build, install = minimal_parts(tmp)
        out = tmp / "merged.json"
        result = run_merge(mac, build, install, out)
        if result.returncode != 0:
            raise AssertionError(result.stderr or result.stdout)
        data = json.loads(out.read_text(encoding="utf-8"))
        if data["build_host"]["alias"] != "build@example":
            raise AssertionError(data)
        if data["release"]["version"] != "0.1.0":
            raise AssertionError(data)
        if data["install"]["uninstall_first"] is not True:
            raise AssertionError(data)
        if data["report"]["final_ok"] is not True:
            raise AssertionError(data)


def test_rejects_wrong_top_level_in_mac() -> None:
    with tempfile.TemporaryDirectory(prefix="merge-release-configs-") as tmp_dir:
        tmp = Path(tmp_dir)
        mac, build, install = minimal_parts(tmp)
        write(
            mac,
            """
build_host:
  alias: build@example
target_host:
  alias: target@example
  state_dir: /var/lib/zon/state
report:
  final_ok: false
install:
  skip: false
""".lstrip(),
        )
        out = tmp / "merged.json"
        result = run_merge(mac, build, install, out)
        if result.returncode == 0:
            raise AssertionError("unexpected success")
        if "unexpected top-level" not in (result.stderr or ""):
            raise AssertionError(result.stderr)


def test_rejects_missing_required_top_level() -> None:
    with tempfile.TemporaryDirectory(prefix="merge-release-configs-") as tmp_dir:
        tmp = Path(tmp_dir)
        mac, build, install = minimal_parts(tmp)
        write(
            install,
            """
install:
  skip: false
verification:
  status_command: true
""".lstrip(),
        )
        out = tmp / "merged.json"
        result = run_merge(mac, build, install, out)
        if result.returncode == 0:
            raise AssertionError("unexpected success")
        if "missing required top-level key: client_verification" not in (result.stderr or ""):
            raise AssertionError(result.stderr)


def main() -> None:
    test_merges_disjoint_role_configs()
    test_rejects_wrong_top_level_in_mac()
    test_rejects_missing_required_top_level()
    print("merge-release-configs tests passed")


if __name__ == "__main__":
    main()
