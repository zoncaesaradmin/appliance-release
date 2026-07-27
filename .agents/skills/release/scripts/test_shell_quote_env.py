#!/usr/bin/env python3
"""Regression tests for shell_quote + env-prefix remote command construction.

Guards against the build-and-publish bootstrap failure mode where a broken
`export NAME=$(shell_quote ...) ;` concatenation left a residual local command
fragment such as `RAP_REGISTRY_TOKEN}) ;`.
"""

from __future__ import annotations

import os
import subprocess
import unittest
from pathlib import Path


COMMON = Path(__file__).resolve().parent / "common.sh"


def run_bash(script: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    merged = os.environ.copy()
    # Keep ambient registry tokens from leaking into assertions.
    merged.pop("REGISTRY_TOKEN", None)
    if env:
        merged.update(env)
    return subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
        env=merged,
    )


APPEND_HELPER = r"""
append_env_assignment() {
  local current="$1"
  local name="$2"
  local value="$3"
  if [[ -z "${value}" ]]; then
    printf '%s' "${current}"
    return 0
  fi
  printf '%s%s=%s ' "${current}" "${name}" "$(shell_quote "${value}")"
}
"""


class ShellQuoteEnvTests(unittest.TestCase):
    def test_append_env_assignment_survives_metacharacters(self) -> None:
        cases = [
            "plain-token",
            "tok)with)parens",
            "tok;with;semicolons",
            "tok$(id)subst",
            "tok`id`ticks",
            "tok'with'quotes",
            'tok"with"dquotes',
            "tok with spaces",
            "tok!history",
            "tok&background",
            "tok|pipe",
        ]
        for token in cases:
            with self.subTest(token=token):
                script = f"""
set -euo pipefail
set +H
source {COMMON.as_posix()!r}
{APPEND_HELPER}
prefix=""
prefix="$(append_env_assignment "${{prefix}}" "CODE_REPO_REF" "main")"
prefix="$(append_env_assignment "${{prefix}}" "REGISTRY_USER" "user")"
prefix="$(append_env_assignment "${{prefix}}" "REGISTRY_TOKEN" "$TOKEN")"
# Same shape as build-and-publish: NAME=quoted-value child-command.
# printenv reads REGISTRY_TOKEN from the child environment (correct for
# bootstrap/build/publish); it does not rely on shell argv expansion.
remote_cmd="cd /tmp && set -euo pipefail && ${{prefix}}printenv REGISTRY_TOKEN"
bash -n -c "${{remote_cmd}}"
got="$(bash -c "${{remote_cmd}}")"
[[ "${{got}}" == "$TOKEN" ]] || {{
  echo "token round-trip failed got=${{got}}" >&2
  exit 1
}}
case "${{remote_cmd}}" in
  *'RAP_REGISTRY_TOKEN}}'* | *'export REGISTRY_TOKEN=$('* )
    echo "unexpected legacy/residual form in remote_cmd: ${{remote_cmd}}" >&2
    exit 1
    ;;
esac
printf 'ok\\n'
"""
                result = run_bash(script, env={"TOKEN": token})
                self.assertEqual(
                    result.returncode,
                    0,
                    msg=f"stdout={result.stdout!r} stderr={result.stderr!r}",
                )
                self.assertEqual(result.stdout.strip(), "ok")

    def test_run_ssh_quote_variable_form_parses(self) -> None:
        script = f"""
set -euo pipefail
set +H
source {COMMON.as_posix()!r}
remote_command="REGISTRY_TOKEN=$(shell_quote 'tok) ; evil') printenv REGISTRY_TOKEN"
quoted_remote_command="$(shell_quote "${{remote_command}}")"
bash -n -c "env -u BASH_ENV PS1='' bash -lc ${{quoted_remote_command}}"
got="$(bash -c "env -u BASH_ENV PS1='' bash -lc ${{quoted_remote_command}}")"
[[ "${{got}}" == 'tok) ; evil' ]] || {{
  echo "got=${{got}}" >&2
  exit 1
}}
printf 'ok\\n'
"""
        result = run_bash(script)
        self.assertEqual(result.returncode, 0, msg=f"stdout={result.stdout!r} stderr={result.stderr!r}")
        self.assertEqual(result.stdout.strip(), "ok")

    def test_legacy_export_form_can_leave_residual_command(self) -> None:
        # Document the failure mode we removed: unquoted token with ')' closes
        # $(shell_quote ...) early and drops the remainder from the assignment.
        script = f"""
set -euo pipefail
set +H
source {COMMON.as_posix()!r}
BOOTSTRAP_REGISTRY_TOKEN='x) ; residual_should_run'
bootstrap_env_prefix=""
# Intentionally broken (unquoted token) — do not use this pattern.
bootstrap_env_prefix="${{bootstrap_env_prefix}}export REGISTRY_TOKEN=$(shell_quote ${{BOOTSTRAP_REGISTRY_TOKEN}}) ; "
printf '%s\\n' "${{bootstrap_env_prefix}}"
"""
        result = run_bash(script)
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertIn("REGISTRY_TOKEN=", result.stdout)
        self.assertNotIn("residual_should_run", result.stdout)


if __name__ == "__main__":
    unittest.main()
