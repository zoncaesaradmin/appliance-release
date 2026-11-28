---
name: appliance-release-loop
description: Run the complete Zon three-repository commit, dependency-seed, build, publish, install, and verify workflow with bounded repair retries.
---

# Appliance release loop

Use this skill when a release must move from local source changes through all
three repositories and then through the existing build-host/target workflow.
The deterministic entrypoint is the tracked script
`../release/scripts/run-release-loop.sh`; it is usable from a Codex devhost,
the Hermes host, or another machine with the three repositories and SSH access.

The script does not replace the product release path. It calls
`run-release-from-devhost.sh` with the three existing role configs, and only
adds the surrounding commit/push, automatic offline dependency seeding, and
bounded retry behavior.

## Run it

Pass the same three role configs used by the existing release command. Run
from either the Mac or Hermes host:

```bash
bash .agents/skills/release/scripts/run-release-loop.sh \
  --config ~/geo-ec2-devhost.yaml \
  --build-publish-config ~/geo-ec2-build-publish.yaml \
  --install-config ~/geo-ec2-install.yaml
```

The three paths are passed unchanged to `run-release-from-devhost.sh` as
`--config`, `--build-publish-config`, and `--install-config`. The build host
and target host remain the `build_host` and `target_host` values in the
existing devhost config, so they may be entirely different machines from the
caller.

The wrapper derives the repository root, commit helper, commit message, build
host, remote checkout path, target architecture, and retry policy itself.

## Failure and repair contract

The release runner returns success only after build/publish, installation, and
post-install verification complete. On failure, the script preserves a run
directory containing the commit, dependency, release, and repair logs. If
If an offline build fails with a dependency/build-input signature, the wrapper
automatically runs `TARGET_ARCH=<configured-arch> make seed-build-deps` on the
configured build host and retries once. Other failures stop with their logs;
the agent/operator fixes the source and reruns this same command.

Retries are bounded by `retry.max_attempts` (default 3, maximum 20). Without a
repair hook the script stops after the first failed release instead of blindly
repeating an unchanged deployment. A repair hook must not push: the existing
`appliance-three-repo-commit` helper owns review, commit, and push.

Do not use this skill to bypass the release skill's signed-bundle checks,
offline policy, or real-setup guardrail. A real run requires the operator to
invoke the script with the intended host configs.
