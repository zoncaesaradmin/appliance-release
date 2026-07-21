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


def test_clone_when_missing() -> None:
    cmd = render(
        "/home/zonsys/ws/appliance-release",
        "git@github.com:zoncaesaradmin/appliance-release.git",
        "main",
        "git pull",
    )
    assert "clone_release_repo()" in cmd
    assert "git clone --depth 1 --branch" in cmd
    assert "git@github.com:zoncaesaradmin/appliance-release.git" in cmd


def test_existing_checkout_hard_resets_instead_of_pull() -> None:
    cmd = render(
        "/home/zonsys/ws/appliance-release",
        "git@github.com:zoncaesaradmin/appliance-release.git",
        "main",
        "git pull",
    )
    assert "sync_existing_release_repo()" in cmd
    assert "git reset --hard FETCH_HEAD" in cmd
    assert "git clean -fd" in cmd
    # Managed sync must not rely on plain git pull (fails on dirty trees),
    # even when build_flow.git_pull_command is still set in config.
    assert "git pull" not in cmd


def test_non_git_path_is_replaced() -> None:
    cmd = render(
        "/home/zonsys/ws/appliance-release",
        "git@github.com:zoncaesaradmin/appliance-release.git",
        "main",
        "",
    )
    assert "path exists but is not a git checkout; replacing" in cmd
    assert "rm -rf" in cmd


def test_failed_sync_reclones() -> None:
    cmd = render(
        "/home/zonsys/ws/appliance-release",
        "git@github.com:zoncaesaradmin/appliance-release.git",
        "main",
        "git pull",
    )
    assert "removing unusable checkout" in cmd


def main() -> None:
    test_clone_when_missing()
    test_existing_checkout_hard_resets_instead_of_pull()
    test_non_git_path_is_replaced()
    test_failed_sync_reclones()
    print("ensure remote release repo tests passed")


if __name__ == "__main__":
    main()
