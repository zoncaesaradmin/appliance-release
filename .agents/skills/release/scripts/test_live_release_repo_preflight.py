#!/usr/bin/env python3
from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path


COMMON_SH = Path(__file__).resolve().parent / "common.sh"


def run(cmd: list[str], cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, cwd=cwd, check=True, text=True, capture_output=True)


def init_repo(tmp_dir: Path) -> Path:
    origin = tmp_dir / "origin.git"
    repo = tmp_dir / "repo"
    run(["git", "init", "--bare", "--initial-branch=main", str(origin)])
    run(["git", "clone", str(origin), str(repo)])
    run(["git", "config", "user.name", "Codex"], cwd=repo)
    run(["git", "config", "user.email", "codex@example.invalid"], cwd=repo)
    (repo / "tracked.txt").write_text("base\n", encoding="utf-8")
    run(["git", "add", "tracked.txt"], cwd=repo)
    run(["git", "commit", "-m", "initial"], cwd=repo)
    run(["git", "push", "-u", "origin", "main"], cwd=repo)
    return repo


def run_preflight(repo: Path, remote_ref: str = "main") -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "bash",
            "-lc",
            (
                f'source "{COMMON_SH}"; '
                f'assert_local_repo_clean_for_remote_ref "{repo}" "appliance-ctl" "{remote_ref}"'
            ),
        ],
        check=False,
        text=True,
        capture_output=True,
    )


def test_clean_repo_passes() -> None:
    with tempfile.TemporaryDirectory(prefix="live-release-preflight-") as tmp:
        repo = init_repo(Path(tmp))
        result = run_preflight(repo)
        assert result.returncode == 0, result.stderr


def test_dirty_build_affecting_repo_fails() -> None:
    with tempfile.TemporaryDirectory(prefix="live-release-preflight-") as tmp:
        repo = init_repo(Path(tmp))
        scripts = repo / "scripts"
        scripts.mkdir()
        (scripts / "build.sh").write_text("#!/bin/bash\n", encoding="utf-8")
        run(["git", "add", "scripts/build.sh"], cwd=repo)
        run(["git", "commit", "-m", "add script"], cwd=repo)
        run(["git", "push"], cwd=repo)
        (scripts / "build.sh").write_text("#!/bin/bash\necho dirty\n", encoding="utf-8")
        result = run_preflight(repo)
        assert result.returncode != 0
        assert "uncommitted build-affecting changes" in result.stderr


def test_dirty_docs_only_repo_warns_and_passes() -> None:
    with tempfile.TemporaryDirectory(prefix="live-release-preflight-") as tmp:
        repo = init_repo(Path(tmp))
        docs = repo / "docs"
        docs.mkdir()
        (docs / "notes.md").write_text("local notes\n", encoding="utf-8")
        result = run_preflight(repo)
        assert result.returncode == 0, result.stderr
        assert "local-only uncommitted changes" in result.stderr


def test_placeholder_client_base_url_fails() -> None:
    result = subprocess.run(
        [
            "bash",
            "-lc",
            (
                f'source "{COMMON_SH}"; '
                'reject_placeholder_client_base_url "https://target-ip-or-dns" "client_verification.base_url"'
            ),
        ],
        check=False,
        text=True,
        capture_output=True,
    )
    assert result.returncode != 0
    assert "example placeholder" in result.stderr


def test_real_client_base_url_passes() -> None:
    result = subprocess.run(
        [
            "bash",
            "-lc",
            (
                f'source "{COMMON_SH}"; '
                'reject_placeholder_client_base_url "https://192.168.1.103" "client_verification.base_url"'
            ),
        ],
        check=False,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr


def test_rewrite_command_url_path_to_base() -> None:
    result = subprocess.run(
        [
            "bash",
            "-lc",
            (
                f'source "{COMMON_SH}"; '
                "rewrite_command_url_path_to_base "
                "'code=\"$(curl -ksS https://192.168.1.101/api/v1/work-profiles)\"' "
                "'https://192.168.1.151' "
                "'/api/v1/work-profiles'"
            ),
        ],
        check=False,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout == 'code="$(curl -ksS https://192.168.1.151/api/v1/work-profiles)"'


def test_expand_legacy_ui_home_command_for_spa() -> None:
    legacy = (
        'body="$(curl -kfsS https://192.168.1.151/)" && '
        'printf "%s" "$body" | grep -Eiq "Zon Appliance|Sign in to continue|Appliance status|Create first administrator"'
    )
    result = subprocess.run(
        [
            "bash",
            "-lc",
            (
                f'source "{COMMON_SH}"; '
                f"expand_legacy_ui_home_command_for_spa {legacy!r}"
            ),
        ],
        check=False,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Create first administrator|Appliance Control Plane UI" in result.stdout
    assert "appliance-controlplane-ui" in result.stdout


def test_derive_mdns_tls_san_from_hostname() -> None:
    result = subprocess.run(
        [
            "bash",
            "-lc",
            (
                f'source "{COMMON_SH}"; '
                'san="$(derive_mdns_tls_san_from_hostname "Demo-Host.example.internal")"; '
                '[[ "${san}" == "demo-host.local" ]]'
            ),
        ],
        check=False,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr

    invalid = subprocess.run(
        [
            "bash",
            "-lc",
            (
                f'source "{COMMON_SH}"; '
                'derive_mdns_tls_san_from_hostname "_invalid_hostname"'
            ),
        ],
        check=False,
        text=True,
        capture_output=True,
    )
    assert invalid.returncode != 0


def test_profile_capability_helpers() -> None:
    result = subprocess.run(
        [
            "bash",
            "-lc",
            (
                f'source "{COMMON_SH}"; '
                'profile_supports_builder builder && '
                '! profile_supports_builder storage && '
                'profile_supports_artifacts storage-landns && '
                '! profile_supports_artifacts core && '
                'profile_supports_workflows core && '
                '! profile_supports_workflows storage'
            ),
        ],
        check=False,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr


def test_require_builder_build_catalog_helper() -> None:
    with tempfile.TemporaryDirectory(prefix="builder-catalog-helper-") as tmp:
        catalog = Path(tmp) / "catalog.yaml"
        catalog.write_text("buildTargets: []\n", encoding="utf-8")
        pass_result = subprocess.run(
            [
                "bash",
                "-lc",
                (
                    f'source "{COMMON_SH}"; '
                    f'require_builder_build_catalog_path core ""; '
                    f'require_builder_build_catalog_path builder "{catalog}"'
                ),
            ],
            check=False,
            text=True,
            capture_output=True,
        )
        assert pass_result.returncode == 0, pass_result.stderr

        fail_result = subprocess.run(
            [
                "bash",
                "-lc",
                f'source "{COMMON_SH}"; require_builder_build_catalog_path builder ""',
            ],
            check=False,
            text=True,
            capture_output=True,
        )
        assert fail_result.returncode != 0
        assert "builder appliance profile requires install.build_catalog_path" in fail_result.stderr


def test_csv_items_trimmed_and_workflow_guard_helpers() -> None:
    result = subprocess.run(
        [
            "bash",
            "-lc",
            (
                f'source "{COMMON_SH}"; '
                'joined="$(csv_items_trimmed \' one.example , two.example,, three.example \' | tr \'\\n\' \',\')"; '
                '[[ "${joined}" == "one.example,two.example,three.example," ]]; '
                'require_profile_supports_workflows true core verification.argo.enabled'
            ),
        ],
        check=False,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr

    fail_result = subprocess.run(
        [
            "bash",
            "-lc",
            (
                f'source "{COMMON_SH}"; '
                'require_profile_supports_workflows true storage verification.argo.enabled'
            ),
        ],
        check=False,
        text=True,
        capture_output=True,
    )
    assert fail_result.returncode != 0
    assert "verification.argo.enabled=true but install.appliance_profile=storage does not enable workflows" in fail_result.stderr


def test_inject_env_path_after_sudo_helper() -> None:
    result = subprocess.run(
        [
            "bash",
            "-lc",
            (
                f'source "{COMMON_SH}"; '
                'rewritten="$(inject_env_path_after_sudo '
                '\'sudo kubectl get pods -A && sudo kubectl get svc\' '
                '\'/bundle/bin:/usr/bin\')"; '
                '[[ "${rewritten}" == '
                '"sudo env PATH=/bundle/bin:/usr/bin kubectl get pods -A && '
                'sudo env PATH=/bundle/bin:/usr/bin kubectl get svc" ]]'
            ),
        ],
        check=False,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr


def test_require_config_path_helper() -> None:
    with tempfile.TemporaryDirectory(prefix="config-path-helper-") as tmp:
        config = Path(tmp) / "appliance-release.config.yaml"
        config.write_text("release:\n  version: 0.1.0\n", encoding="utf-8")
        pass_result = subprocess.run(
            [
                "bash",
                "-lc",
                (
                    f'source "{COMMON_SH}"; '
                    f'got="$(require_config_path "{config}")"; '
                    f'[[ "${{got}}" == "{config}" ]]'
                ),
            ],
            check=False,
            text=True,
            capture_output=True,
        )
        assert pass_result.returncode == 0, pass_result.stderr

        fail_result = subprocess.run(
            [
                "bash",
                "-lc",
                f'source "{COMMON_SH}"; require_config_path ""',
            ],
            check=False,
            text=True,
            capture_output=True,
        )
        assert fail_result.returncode != 0
        assert "config not provided; use --config PATH" in fail_result.stderr


def test_release_run_dir_helpers() -> None:
    with tempfile.TemporaryDirectory(prefix="run-dir-helper-") as tmp:
        run_dir = Path(tmp) / "custom-run"
        result = subprocess.run(
            [
                "bash",
                "-lc",
                (
                    f'source "{COMMON_SH}"; '
                    f'cd "{tmp}"; '
                    'generated="$(default_release_run_dir)"; '
                    '[[ "${generated}" == "$PWD/.run/appliance-release/"* ]]; '
                    f'ensure_release_run_dirs "{run_dir}" artifacts; '
                    f'[[ -d "{run_dir}" && -d "{run_dir}/logs" && -d "{run_dir}/metadata" && -d "{run_dir}/artifacts" ]]'
                ),
            ],
            check=False,
            text=True,
            capture_output=True,
        )
        assert result.returncode == 0, result.stderr


def test_require_appliance_profile_helper() -> None:
    with tempfile.TemporaryDirectory(prefix="appliance-profile-helper-") as tmp:
        config = Path(tmp) / "appliance-release.config.yaml"
        config.write_text("install:\n  appliance_profile: builder\n", encoding="utf-8")
        pass_result = subprocess.run(
            [
                "bash",
                "-lc",
                (
                    f'source "{COMMON_SH}"; '
                    f'from_config="$(require_appliance_profile "{config}" "")"; '
                    f'override="$(require_appliance_profile "{config}" core)"; '
                    '[[ "${from_config}" == "builder" && "${override}" == "core" ]]'
                ),
            ],
            check=False,
            text=True,
            capture_output=True,
        )
        assert pass_result.returncode == 0, pass_result.stderr

        missing_config = Path(tmp) / "missing-profile.yaml"
        missing_config.write_text("install: {}\n", encoding="utf-8")
        default_result = subprocess.run(
            [
                "bash",
                "-lc",
                (
                    f'source "{COMMON_SH}"; '
                    f'defaulted="$(require_appliance_profile "{missing_config}" "")"; '
                    '[[ "${defaulted}" == "core" ]]'
                ),
            ],
            check=False,
            text=True,
            capture_output=True,
        )
        assert default_result.returncode == 0, default_result.stderr


def test_resolve_build_catalog_path_helper() -> None:
    with tempfile.TemporaryDirectory(prefix="build-catalog-helper-") as tmp:
        catalog = Path(tmp) / "catalog.yaml"
        catalog.write_text("buildTargets: []\n", encoding="utf-8")
        config = Path(tmp) / "appliance-release.config.yaml"
        config.write_text(f"install:\n  build_catalog_path: {catalog}\n", encoding="utf-8")
        pass_result = subprocess.run(
            [
                "bash",
                "-lc",
                (
                    f'source "{COMMON_SH}"; '
                    f'from_config="$(resolve_build_catalog_path "{config}" "")"; '
                    f'override="$(resolve_build_catalog_path "{config}" "{catalog}")"; '
                    f'[[ "${{from_config}}" == "{catalog}" && "${{override}}" == "{catalog}" ]]'
                ),
            ],
            check=False,
            text=True,
            capture_output=True,
        )
        assert pass_result.returncode == 0, pass_result.stderr

        missing = Path(tmp) / "missing.yaml"
        fail_result = subprocess.run(
            [
                "bash",
                "-lc",
                f'source "{COMMON_SH}"; resolve_build_catalog_path "{config}" "{missing}"',
            ],
            check=False,
            text=True,
            capture_output=True,
        )
        assert fail_result.returncode != 0
        assert "required file not found" in fail_result.stderr


def main() -> None:
    test_clean_repo_passes()
    test_dirty_build_affecting_repo_fails()
    test_dirty_docs_only_repo_warns_and_passes()
    test_placeholder_client_base_url_fails()
    test_real_client_base_url_passes()
    test_rewrite_command_url_path_to_base()
    test_derive_mdns_tls_san_from_hostname()
    test_profile_capability_helpers()
    test_require_builder_build_catalog_helper()
    test_csv_items_trimmed_and_workflow_guard_helpers()
    test_inject_env_path_after_sudo_helper()
    test_require_config_path_helper()
    test_release_run_dir_helpers()
    test_require_appliance_profile_helper()
    test_resolve_build_catalog_path_helper()
    print("live release repo preflight tests passed")


if __name__ == "__main__":
    main()
