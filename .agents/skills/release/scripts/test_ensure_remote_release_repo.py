#!/usr/bin/env python3
from __future__ import annotations

import subprocess
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
COMMON_SH = SCRIPT_DIR / "common.sh"


def render(remote_cwd: str, repo_source: str, repo_ref: str, pull_cmd: str) -> str:
    proc = subprocess.run(
        [
            "bash",
            "-lc",
            (
                f'source "{COMMON_SH}"; '
                f'render_ensure_remote_release_repo_cmd '
                f'"{remote_cwd}" "{repo_source}" "{repo_ref}" "{pull_cmd}"'
            ),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return proc.stdout


def test_clone_branch_when_missing() -> None:
    cmd = render(
        "/home/zonsys/ws/appliance-release",
        "git@github.com:zoncaesaradmin/appliance-release.git",
        "main",
        "git pull",
    )
    assert "git clone --depth 1 --branch" in cmd
    assert "git@github.com:zoncaesaradmin/appliance-release.git" in cmd
    assert "/home/zonsys/ws/appliance-release" in cmd


def test_pull_when_checkout_exists() -> None:
    cmd = render(
        "/home/zonsys/ws/appliance-release",
        "git@github.com:zoncaesaradmin/appliance-release.git",
        "main",
        "git pull",
    )
    assert 'if [[ -d "${repo_path}/.git" ]]; then' in cmd
    assert "git pull" in cmd


def test_clone_without_pull_command() -> None:
    cmd = render(
        "/home/zonsys/ws/appliance-release",
        "git@github.com:zoncaesaradmin/appliance-release.git",
        "main",
        "",
    )
    assert "git clone --depth 1 --branch" in cmd
    assert "git pull" not in cmd


def main() -> None:
    test_clone_branch_when_missing()
    test_pull_when_checkout_exists()
    test_clone_without_pull_command()
    print("ensure remote release repo tests passed")


if __name__ == "__main__":
    main()
