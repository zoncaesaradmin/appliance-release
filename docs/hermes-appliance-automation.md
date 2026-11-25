# Hermes appliance automation

The Hermes host is the automation runner for small, repeatable appliance
day-2 operations. The runner is deliberately kept on Hermes (`192.168.1.152`)
and streams commands over the existing SSH connections:

```text
Hermes (152) ──SSH──> build host (151) ──push──> artifact server (156)
       └────SSH + streamed sudo script────> appliance target (155)
```

Nothing is installed on the target. A failed target rollout restores the
previous UI image automatically.

## One-time install on Hermes

From a workstation with this repository checked out, copy only the runner to
the Hermes host:

```bash
scp scripts/hermes/appliance-run \
  zonsys@192.168.1.152:/home/zonsys/.local/bin/appliance-run
ssh zonsys@192.168.1.152 \
  'chmod 0750 /home/zonsys/.local/bin/appliance-run'
```

The protected sudo password file belongs only on Hermes:

```text
/home/zonsys/.config/zon-appliance-automation/secrets/target-default.sudo
```

It must be owned by `zonsys` and mode `600`. The runner reads it only to feed
`sudo -S` on the target; it never puts the password in an argument or log.

## Generic image refresh workflow

Run directly on Hermes:

```bash
/home/zonsys/.local/bin/appliance-run image-refresh --service ui --source-ref main
```

The old `ui-refresh --source-ref main` form remains a compatibility alias.

Multiple services can be refreshed in one ordered run:

```bash
/home/zonsys/.local/bin/appliance-run \
  image-refresh \
  --service ui,identity,ordering \
  --source-ref main
```

The runner holds one lock and writes one log for the run. Services are built
and rolled out in the order given; it stops on the first failure, while earlier
successful rollouts remain deployed.

The same command supports the currently deployed code-backed services:

```bash
/home/zonsys/.local/bin/appliance-run image-refresh --service controlplane
/home/zonsys/.local/bin/appliance-run image-refresh --service host-agent
/home/zonsys/.local/bin/appliance-run image-refresh --service channel-integration
/home/zonsys/.local/bin/appliance-run image-refresh --service identity
/home/zonsys/.local/bin/appliance-run image-refresh --service ordering
/home/zonsys/.local/bin/appliance-run image-refresh --service workflow-controller
/home/zonsys/.local/bin/appliance-run image-refresh --service artifact-server
/home/zonsys/.local/bin/appliance-run image-refresh --service dns-server
/home/zonsys/.local/bin/appliance-run image-refresh --service inference-manager
/home/zonsys/.local/bin/appliance-run image-refresh --service open-webui-gateway
```

Each service is an allowlisted mapping to its source directory, image name,
Kubernetes namespace, deployment, and container. The workflow verifies a clean
build checkout, fetches the requested ref on 151, builds only that service,
pushes an immutable digest to 156, and updates the mapped deployment on 155.
It waits for rollout completion and rolls back the old image if the new pod
does not become ready. Normal signed bundles preload images and use
`imagePullPolicy: Never`; this targeted workflow switches the selected
deployment to `IfNotPresent` so the registry digest can be pulled, while
restoring the previous policy if the rollout fails.

The same operation can be requested through the Hermes agent, for example:

```bash
hermes -z 'Run exactly /home/zonsys/.local/bin/appliance-run image-refresh --service ui --source-ref main and report the result.'
```

Hermes should be instructed to use this allowlisted command, not to invent a
new `ssh`, `sudo`, or Kubernetes command. The runner writes logs on Hermes at
`~/.local/state/zon-appliance-automation/logs/` and serializes runs with a
lock, so overlapping refreshes are rejected.

## Configuration overrides

The defaults match the current LAN layout. For another target, set environment
variables on Hermes rather than editing the runner:

```bash
export APPLIANCE_TARGET_HOST=zonsys@192.168.1.155
export APPLIANCE_BUILD_HOST=zonsys@192.168.1.151
export APPLIANCE_REGISTRY_HOST=192.168.1.156
export APPLIANCE_SUDO_PASSWORD_FILE="$HOME/.config/zon-appliance-automation/secrets/target-default.sudo"
```

No full release bundle is created by this workflow. Use the existing signed
release runner for a complete appliance release; use this runner only for
targeted code-backed service image refreshes.
