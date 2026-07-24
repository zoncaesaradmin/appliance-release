#!/usr/bin/env python3
from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
COMMON_SH = SCRIPT_DIR / "common.sh"


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


def test_dirty_repo_fails() -> None:
    with tempfile.TemporaryDirectory(prefix="live-release-preflight-") as tmp:
        repo = init_repo(Path(tmp))
        (repo / "tracked.txt").write_text("dirty\n", encoding="utf-8")
        result = run_preflight(repo)
        assert result.returncode != 0
        assert "has uncommitted changes" in result.stderr
        assert "will ignore local edits" in result.stderr


def test_repo_ahead_of_remote_ref_fails() -> None:
    with tempfile.TemporaryDirectory(prefix="live-release-preflight-") as tmp:
        repo = init_repo(Path(tmp))
        (repo / "tracked.txt").write_text("ahead\n", encoding="utf-8")
        run(["git", "add", "tracked.txt"], cwd=repo)
        run(["git", "commit", "-m", "ahead"], cwd=repo)
        result = run_preflight(repo)
        assert result.returncode != 0
        assert "ahead of origin/main by 1 commit(s)" in result.stderr
        assert "will not be included" in result.stderr


def main() -> None:
    test_clean_repo_passes()
    test_dirty_repo_fails()
    test_repo_ahead_of_remote_ref_fails()
    print("live release repo preflight tests passed")


if __name__ == "__main__":
    main()
