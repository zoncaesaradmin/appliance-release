#!/usr/bin/env python3
"""Smoke-test the release loop with local fake commit/release/repair commands."""

import os
import shutil
import stat
import subprocess
import tempfile
from pathlib import Path


SCRIPT = Path(__file__).with_name("run-release-loop.sh")


def write_executable(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def run_case() -> None:
    with tempfile.TemporaryDirectory(prefix="release-loop-test-") as raw:
        root = Path(raw)
        repos = root / "ws"
        repos.mkdir()
        for name in ("appliance-release", "appliance-ctl", "appliance-code"):
            (repos / name).mkdir()

        copied_script_dir = repos / "appliance-release" / ".agents/skills/release/scripts"
        copied_script_dir.mkdir(parents=True)
        shutil.copy2(SCRIPT, copied_script_dir / SCRIPT.name)
        shutil.copy2(SCRIPT.with_name("common.sh"), copied_script_dir / "common.sh")
        shutil.copy2(SCRIPT.with_name("config_query.py"), copied_script_dir / "config_query.py")

        state = root / "state"
        state.mkdir()
        fake_bin = root / "bin"
        fake_bin.mkdir()
        commit_log = state / "commit.log"
        release_count = state / "release.count"
        seeded = state / "seeded"

        commit = state / "commit.sh"
        write_executable(
            commit,
            "#!/usr/bin/env bash\n"
            "set -eu\n"
            "printf '%s\\n' \"$*\" >> \"$COMMIT_LOG\"\n",
        )
        runner = copied_script_dir / "run-release-from-devhost.sh"
        write_executable(
            runner,
            "#!/usr/bin/env bash\n"
            "set -eu\n"
            "n=0; [[ -f \"$RELEASE_COUNT\" ]] && n=$(cat \"$RELEASE_COUNT\")\n"
            "n=$((n + 1)); printf '%s' \"$n\" > \"$RELEASE_COUNT\"\n"
            "if [[ ! -f \"$SEEDED\" ]]; then echo 'build-and-publish: dependency missing' >&2; exit 7; fi\n"
            "echo release-success\n",
        )
        ssh = fake_bin / "ssh"
        write_executable(
            ssh,
            "#!/usr/bin/env bash\n"
            "set -eu\n"
            "cmd=\"${!#}\"\n"
            "if [[ \"$cmd\" == *seed-build-deps* ]]; then touch \"$SEEDED\"; exit 0; fi\n"
            "echo \"unexpected fake ssh command: $cmd\" >&2; exit 1\n",
        )

        (root / "devhost.yaml").write_text(
            "build_host:\n  alias: fake-build\n"
            "target_host:\n  alias: fake-target\n",
            encoding="utf-8",
        )
        (root / "build.yaml").write_text(
            "release_workspace:\n"
            f"  remote_build_root: {root / 'remote-build'}\n"
            "build_flow:\n"
            "  mode: offline\n"
            "  target_arch: amd64\n"
            "bundle_store:\n"
            "  mode: static_http\n"
            "  base_url: http://127.0.0.1:8080\n"
            f"  publish_directory: {root / 'publish'}\n",
            encoding="utf-8",
        )
        (root / "install.yaml").write_text("install: {}\n", encoding="utf-8")
        (root / "remote-build" / "release").mkdir(parents=True)
        home = root / "home"
        commit = home / ".codex/skills/appliance-three-repo-commit/scripts/three-repo-commit.sh"
        commit.parent.mkdir(parents=True)
        write_executable(
            commit,
            "#!/usr/bin/env bash\n"
            "set -eu\n"
            "printf '%s\\n' \"$*\" >> \"$COMMIT_LOG\"\n",
        )
        env = os.environ | {
            "COMMIT_LOG": str(commit_log),
            "RELEASE_COUNT": str(release_count),
            "SEEDED": str(seeded),
            "APPLIANCE_BUILD_SUDO_PASSWORD": "test-password",
            "HOME": str(home),
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
        }
        result = subprocess.run(
            ["bash", str(copied_script_dir / SCRIPT.name),
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
        assert seeded.exists()


if __name__ == "__main__":
    run_case()
    print("run-release-loop smoke test passed")
