# Appliance Release Script Usage

Okay these exports you enable first and then run the script:

```bash
export APPLIANCE_RELEASE_CONFIG=/Users/zoncaesar/ws/appliance-release/appliance-release.config.yaml
export REGISTRY_USER=zoncaesaradmin
export REGISTRY_TOKEN='...'
export APPLIANCE_BUILD_SUDO_PASSWORD='caesar'
export APPLIANCE_TARGET_SUDO_PASSWORD='caesar'
export APPLIANCE_FIRST_ADMIN_PASSWORD='ins3965!'
```

Notes:

- `APPLIANCE_RELEASE_CONFIG` is the main common input for all scripts.
- If `APPLIANCE_RELEASE_CONFIG` is set, you usually do not need `--config`.
- `REGISTRY_TOKEN` is mainly needed for build-host bootstrap and build.
- `APPLIANCE_FIRST_ADMIN_PASSWORD` is used both for install and Mac-side API verification.

## 1. Full Flow

Use this for the normal end-to-end workflow.

```bash
/Users/zoncaesar/ws/appliance-release/.agents/skills/scripts/run-release-flow.sh
```

Common explicit example:

```bash
/Users/zoncaesar/ws/appliance-release/.agents/skills/scripts/run-release-flow.sh \
  --release-version 0.1.0 \
  --uninstall-first \
  --final-ok
```

This does:

- build and publish on the build host
- install on the target host
- verify on the target host
- verify login/session/users from the Mac

## 2. Build And Publish Only

Use this if you only want the remote build and publish step.

```bash
/Users/zoncaesar/ws/appliance-release/.agents/skills/scripts/build-and-publish.sh
```

Example with an explicit version:

```bash
/Users/zoncaesar/ws/appliance-release/.agents/skills/scripts/build-and-publish.sh \
  --release-version 0.1.0
```

Use this when:

- code is already pushed
- you want the build machine to pull, build, and publish
- you do not want to install yet

## 3. Install On Target Only

Use this when the release is already published and you want only the install step.

```bash
/Users/zoncaesar/ws/appliance-release/.agents/skills/scripts/install-on-target.sh \
  --release-version 0.1.0 \
  --uninstall-first
```

If you want to keep the current install and test without uninstalling first:

```bash
/Users/zoncaesar/ws/appliance-release/.agents/skills/scripts/install-on-target.sh \
  --release-version 0.1.0
```

This script:

- downloads the published bundle from the HTTP server
- verifies checksums
- extracts the bundle on the target host
- runs `zonctl preflight`
- runs `zonctl install` with the first-admin password from env

## 4. Verify Target Only

Use this after install if you want only target-side verification.

```bash
/Users/zoncaesar/ws/appliance-release/.agents/skills/scripts/verify-target.sh
```

This script checks:

- `zonctl status`
- `zonctl verify`
- pod health with `kubectl get pods -A`
- installed-state version info
- a smoke check from the target host itself
- support bundle collection on failure

If your config enables `verification.argo.enabled: true`, it also checks:

- `appliance-workflows` and `appliance-builds` namespaces
- core Argo Workflow CRDs
- the Argo controller deployment and pods

## 5. Verify Client/API Only

Use this from the Mac if the appliance is already installed and reachable.

```bash
/Users/zoncaesar/ws/appliance-release/.agents/skills/scripts/verify-client-access.sh
```

This script checks:

- `POST /api/v1/auth/login`
- `GET /api/v1/auth/session`
- `GET /api/v1/users`
- writes a clear request log for each API call with method, full URL, sanitized headers, and sanitized POST body fields
- keeps the response body and response headers in separate log files

If you want to override the host or username for a one-off test:

```bash
/Users/zoncaesar/ws/appliance-release/.agents/skills/scripts/verify-client-access.sh \
  --host https://192.168.1.101 \
  --username admin
```

## 6. Config File

Start from:

```bash
/Users/zoncaesar/ws/appliance-release/.agents/skills/appliance-release/references/config.example.yaml
```

Your usual real config lives in the repo, for example:

```bash
/Users/zoncaesar/ws/appliance-release/appliance-release.config.yaml
```

If you keep the optional global symlink at `~/.agents/skills/appliance-release`,
the compatibility path `~/.agents/skills/appliance-release/scripts/...` will
still work. The canonical repo-local script path is `.agents/skills/scripts`.

## 7. Simplest Day-To-Day Usage

Most days, this is enough:

```bash
export APPLIANCE_RELEASE_CONFIG=/Users/zoncaesar/ws/appliance-release/appliance-release.config.yaml
export REGISTRY_USER=zoncaesaradmin
export REGISTRY_TOKEN='...'
export APPLIANCE_BUILD_SUDO_PASSWORD='caesar'
export APPLIANCE_TARGET_SUDO_PASSWORD='caesar'
export APPLIANCE_FIRST_ADMIN_PASSWORD='ins3965!'

/Users/zoncaesar/ws/appliance-release/.agents/skills/scripts/run-release-flow.sh --uninstall-first --final-ok
```
