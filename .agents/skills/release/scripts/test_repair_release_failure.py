#!/usr/bin/env python3
"""Regression tests for deterministic release-loop source repair."""

import os
import shutil
import stat
import subprocess
import tempfile
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
REPAIR = SCRIPT_DIR / "repair-release-failure.sh"
LOOP = SCRIPT_DIR / "run-release-loop.sh"

BAD_LINE = "  POSTGIS_ARCHIVE_ARG_LINES+=$'\\n  --extra-oci-image-reference \"${POSTGIS_IMAGE_REF}\" \\\\'"
GOOD_LINE = "  POSTGIS_ARCHIVE_ARG_LINES+=$'\\n  --extra-oci-image-reference \"\\${POSTGIS_IMAGE_REF}\" \\\\'"


def write_executable(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def create_generator(root: Path) -> Path:
    target = root / "appliance-release/scripts/build-full-bundle.sh"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(f"#!/usr/bin/env bash\n{BAD_LINE}\n", encoding="utf-8")
    return target


def test_repair_hook() -> None:
    with tempfile.TemporaryDirectory(prefix="repair-hook-test-") as raw:
        root = Path(raw)
        target = create_generator(root)
        log = root / "release.log"
        log.write_text("archive-release-input: unknown argument:  \n", encoding="utf-8")
        result = subprocess.run(
            [str(REPAIR), "--release-log", str(log), "--repo-root", str(root)],
            text=True,
            capture_output=True,
            check=False,
        )
        assert result.returncode == 0, (result.stdout, result.stderr)
        assert GOOD_LINE in target.read_text(encoding="utf-8")

        second = subprocess.run(
            [str(REPAIR), "--release-log", str(log), "--repo-root", str(root)],
            text=True,
            capture_output=True,
            check=False,
        )
        assert second.returncode == 3, (second.stdout, second.stderr)

        unrelated = root / "unrelated.log"
        unrelated.write_text("make: failed\n", encoding="utf-8")
        third = subprocess.run(
            [str(REPAIR), "--release-log", str(unrelated), "--repo-root", str(root)],
            check=False,
        )
        assert third.returncode == 3


def test_loop_repairs_before_retry() -> None:
    with tempfile.TemporaryDirectory(prefix="release-loop-repair-test-") as raw:
        root = Path(raw)
        repos = root / "ws"
        (repos / "appliance-release/.agents/skills/release/scripts").mkdir(parents=True)
        (repos / "appliance-release/scripts").mkdir(parents=True)
        for name in ("appliance-ctl", "appliance-code"):
            (repos / name).mkdir()
        shutil.copy2(LOOP, repos / "appliance-release/.agents/skills/release/scripts/run-release-loop.sh")
        shutil.copy2(SCRIPT_DIR / "common.sh", repos / "appliance-release/.agents/skills/release/scripts/common.sh")
        shutil.copy2(SCRIPT_DIR / "config_query.py", repos / "appliance-release/.agents/skills/release/scripts/config_query.py")
        shutil.copy2(REPAIR, repos / "appliance-release/.agents/skills/release/scripts/repair-release-failure.sh")
        create_generator(root / "ws")

        state = root / "state"
        state.mkdir()
        release_count = state / "release.count"
        commit_log = state / "commit.log"
        runner = repos / "appliance-release/.agents/skills/release/scripts/run-release-from-devhost.sh"
        write_executable(
            runner,
            "#!/usr/bin/env bash\n"
            "set -eu\n"
            "n=0; [[ -f \"$RELEASE_COUNT\" ]] && n=$(cat \"$RELEASE_COUNT\")\n"
            "n=$((n + 1)); printf '%s' \"$n\" > \"$RELEASE_COUNT\"\n"
            "if [[ \"$n\" == 1 ]]; then echo 'archive-release-input: unknown argument:  ' >&2; exit 7; fi\n"
            "echo release-success\n",
        )

        home = root / "home"
        commit = home / ".codex/skills/appliance-three-repo-commit/scripts/three-repo-commit.sh"
        commit.parent.mkdir(parents=True)
        write_executable(
            commit,
            "#!/usr/bin/env bash\n"
            "set -eu\n"
            "printf '%s\\n' \"$*\" >> \"$COMMIT_LOG\"\n",
        )

        (root / "devhost.yaml").write_text("build_host:\n  alias: fake-build\n", encoding="utf-8")
        (root / "build.yaml").write_text(
            "release_workspace:\n"
            f"  remote_build_root: {root / 'remote-build'}\n"
            "build_flow:\n"
            "  mode: online\n"
            "  target_arch: amd64\n"
            "bundle_store:\n"
            "  mode: static_http\n"
            "  base_url: http://127.0.0.1:8080\n",
            encoding="utf-8",
        )
        (root / "install.yaml").write_text("install: {}\n", encoding="utf-8")
        (root / "remote-build/release").mkdir(parents=True)

        env = os.environ | {
            "HOME": str(home),
            "RELEASE_COUNT": str(release_count),
            "COMMIT_LOG": str(commit_log),
        }
        result = subprocess.run(
            [
                "bash",
                str(repos / "appliance-release/.agents/skills/release/scripts/run-release-loop.sh"),
                "--config",
                str(root / "devhost.yaml"),
                "--build-publish-config",
                str(root / "build.yaml"),
                "--install-config",
                str(root / "install.yaml"),
            ],
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )
        assert result.returncode == 0, (result.stdout, result.stderr)
        assert "RELEASE_LOOP_OK" in result.stdout
        assert release_count.read_text(encoding="utf-8") == "2"
        assert len(commit_log.read_text(encoding="utf-8").splitlines()) == 2
        assert GOOD_LINE in (repos / "appliance-release/scripts/build-full-bundle.sh").read_text(encoding="utf-8")


if __name__ == "__main__":
    test_repair_hook()
    test_loop_repairs_before_retry()
    print("repair release-loop tests passed")
