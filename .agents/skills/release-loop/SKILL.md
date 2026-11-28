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
adds the surrounding commit/push, optional `make seed-build-deps`, failure
hook, and bounded retry behavior.

## Run it

Create one workflow config using
[references/workflow-config.example.yaml](references/workflow-config.example.yaml),
then run from either the Mac or Hermes host:

```bash
bash .agents/skills/release/scripts/run-release-loop.sh \
  --workflow-config ~/.config/zon/geo-ec2-release.yaml
```

The `repo_root` and all role-config paths are host-local. The build host and
target host remain the `build_host` and `target_host` values in the existing
devhost config, so they may be entirely different machines from the caller.

## Failure and repair contract

The release runner returns success only after build/publish, installation, and
post-install verification complete. On failure, the script preserves a run
directory containing the commit, dependency, release, and repair logs. If
`repair.command` is configured, it is called with environment variables naming
the failed attempt and log; it should inspect the failure and edit local source
only. The wrapper then calls the three-repository commit helper and retries.

Retries are bounded by `retry.max_attempts` (default 3, maximum 20). Without a
repair hook the script stops after the first failed release instead of blindly
repeating an unchanged deployment. A repair hook must not push: the existing
`appliance-three-repo-commit` helper owns review, commit, and push.

Dependency seeding is opt-in. Set `deps.enabled: true` when the configured
build flow is offline and seed `TARGET_ARCH=... make seed-build-deps` on the
build host before the release attempt. The command can run over SSH by setting
`deps.host`; omit it to run locally. Set `deps.before_each_attempt: true` when
repairs can change dependency inputs.

Do not use this skill to bypass the release skill's signed-bundle checks,
offline policy, or real-setup guardrail. A real run requires the operator to
invoke the script with the intended host configs.
