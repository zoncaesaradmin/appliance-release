#!/usr/bin/env python3
"""Smoke-test the release loop with local fake commit/release/repair commands."""

import json
import os
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

        state = root / "state"
        state.mkdir()
        commit_log = state / "commit.log"
        release_count = state / "release.count"
        repair_log = state / "repair.log"

        commit = state / "commit.sh"
        write_executable(
            commit,
            "#!/usr/bin/env bash\n"
            "set -eu\n"
            "printf '%s\\n' \"$*\" >> \"$COMMIT_LOG\"\n",
        )
        runner = state / "runner.sh"
        write_executable(
            runner,
            "#!/usr/bin/env bash\n"
            "set -eu\n"
            "n=0; [[ -f \"$RELEASE_COUNT\" ]] && n=$(cat \"$RELEASE_COUNT\")\n"
            "n=$((n + 1)); printf '%s' \"$n\" > \"$RELEASE_COUNT\"\n"
            "if [[ $n -lt 2 ]]; then echo first-failure >&2; exit 7; fi\n"
            "echo release-success\n",
        )
        repair = state / "repair.sh"
        write_executable(
            repair,
            "#!/usr/bin/env bash\n"
            "set -eu\n"
            "printf '%s\\n' \"$RELEASE_LOOP_RELEASE_LOG\" >> \"$REPAIR_LOG\"\n",
        )

        for path in (root / "devhost.yaml", root / "build.yaml", root / "install.yaml"):
            path.write_text("placeholder: true\n", encoding="utf-8")
        config = root / "workflow.json"
        config.write_text(
            json.dumps(
                {
                    "repo_root": str(repos),
                    "release_root": str(repos / "appliance-release"),
                    "commit": {"script": str(commit), "message": "test release"},
                    "release": {
                        "runner": str(runner),
                        "devhost_config": str(root / "devhost.yaml"),
                        "build_publish_config": str(root / "build.yaml"),
                        "install_config": str(root / "install.yaml"),
                    },
                    "repair": {"command": str(repair), "workdir": str(root)},
                    "retry": {"max_attempts": 2},
                    "run_root": str(root / "runs"),
                }
            ),
            encoding="utf-8",
        )
        env = os.environ | {
            "COMMIT_LOG": str(commit_log),
            "RELEASE_COUNT": str(release_count),
            "REPAIR_LOG": str(repair_log),
        }
        result = subprocess.run(
            ["bash", str(SCRIPT), "--workflow-config", str(config)],
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )
        assert result.returncode == 0, (result.stdout, result.stderr)
        assert "RELEASE_LOOP_OK" in result.stdout
        assert release_count.read_text(encoding="utf-8") == "2"
        assert len(commit_log.read_text(encoding="utf-8").splitlines()) == 2
        assert len(repair_log.read_text(encoding="utf-8").splitlines()) == 1


if __name__ == "__main__":
    run_case()
    print("run-release-loop smoke test passed")
