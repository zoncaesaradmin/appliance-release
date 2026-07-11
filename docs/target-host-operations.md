# Target Host Operations

Audience: target device / target host operator only.

This page is the target-device runbook for a published Zon release.

Use it after the release files have already been published to your HTTP/HTTPS
server. It focuses only on what an operator runs on the target Ubuntu host.

All lifecycle commands below should be run with `sudo`, because the appliance
state directory is `/var/lib/zon` and the installer owns K3s on the host.

## Defaults Used Below

Set these once on the target host before running the commands:

```bash
export RELEASE_BASE_URL=http://192.168.1.103:28081
export RELEASE_VERSION=0.1.0
export STATE_DIR=/var/lib/zon
export WORK_DIR=/tmp/appliance-${RELEASE_VERSION}
```

Replace `RELEASE_BASE_URL` and `RELEASE_VERSION` for your real published
release.

## 1. First Install

This is the normal fresh-host path. It is the only fully wrapped one-command
public installer flow today.

```bash
curl -fsSL "${RELEASE_BASE_URL}/appliance/${RELEASE_VERSION}/install-http-release.sh" \
  | bash -s -- --base-url "${RELEASE_BASE_URL}"
```

What this does:

- downloads `appliance-<version>-bundle.tar.gz`
- downloads `release-signing.pub`
- verifies `sha256sum.txt`
- extracts the bundle under `/tmp/appliance-<version>`
- runs `zonctl preflight`
- runs `zonctl install`
- prompts for the first administrator only when the platform is ready
- installs `zonctl` to `/usr/local/bin/zonctl`

After install, validate with:

```bash
sudo zonctl status --output text
sudo kubectl get pods -A
```

## 2. Upgrade

Use this when Zon is already installed and you want to move to a newer published
release while preserving the appliance state.

The public helper script currently wraps `install`, not `upgrade`, so the
upgrade path is slightly more explicit today.

Download the new release bundle:

```bash
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

curl -fLo "${WORK_DIR}/appliance-${RELEASE_VERSION}-bundle.tar.gz" \
  "${RELEASE_BASE_URL}/appliance/${RELEASE_VERSION}/appliance-${RELEASE_VERSION}-bundle.tar.gz"
curl -fLo "${WORK_DIR}/release-signing.pub" \
  "${RELEASE_BASE_URL}/appliance/${RELEASE_VERSION}/release-signing.pub"
curl -fLo "${WORK_DIR}/sha256sum.txt" \
  "${RELEASE_BASE_URL}/appliance/${RELEASE_VERSION}/sha256sum.txt"

( cd "${WORK_DIR}" && sha256sum -c sha256sum.txt )
tar -C "${WORK_DIR}" -xzf "${WORK_DIR}/appliance-${RELEASE_VERSION}-bundle.tar.gz"
chmod +x "${WORK_DIR}/appliance-${RELEASE_VERSION}-bundle/zonctl"
```

Run preflight and upgrade:

```bash
sudo "${WORK_DIR}/appliance-${RELEASE_VERSION}-bundle/zonctl" preflight --output text
sudo "${WORK_DIR}/appliance-${RELEASE_VERSION}-bundle/zonctl" upgrade \
  --bundle-dir "${WORK_DIR}/appliance-${RELEASE_VERSION}-bundle" \
  --public-key "${WORK_DIR}/release-signing.pub" \
  --state-dir "${STATE_DIR}" \
  --output text
```

Notes:

- `upgrade` requires an existing `installed-state.json` under `STATE_DIR`
- `upgrade` takes a verified pre-upgrade backup automatically
- if the upgrade fails after mutation starts, `zonctl` attempts rollback

## 3. Clean Recovery After A Failed Or Interrupted Run

Use this when a previous `install`, `upgrade`, or other mutating command was
interrupted or left the host in a partial state.

First try:

```bash
sudo zonctl repair --state-dir "${STATE_DIR}" --output text
```

Then rerun the intended operation:

- rerun the first-install curl command if this was a fresh install attempt
- rerun the explicit `upgrade` command if this was an upgrade attempt

Use this path before reaching for a destructive reset.

## 4. Uninstall While Preserving Data

Use this when you want to remove the running appliance from the host but keep
the appliance data directory for later recovery or inspection.

```bash
sudo zonctl uninstall \
  --state-dir "${STATE_DIR}" \
  --confirm <token> \
  --output text
```

Notes:

- this is destructive to the running platform, but not to the preserved data
- the required confirmation token is enforced by `zonctl`
- use `sudo zonctl uninstall --help` on the target host if you need the exact
  current CLI help text for your installed `zonctl` build

## 5. Factory Reset

Use this only when you want to wipe the appliance state and return the host to
a clean slate before reinstalling.

With a verified backup:

```bash
sudo zonctl factory-reset \
  --state-dir "${STATE_DIR}" \
  --confirm <token> \
  --acknowledge-data-loss \
  --backup-id <backup-id> \
  --output text
```

Without preserving data:

```bash
sudo zonctl factory-reset \
  --state-dir "${STATE_DIR}" \
  --confirm <token> \
  --acknowledge-data-loss \
  --force-data-loss \
  --output text
```

After `factory-reset`, run the fresh install again:

```bash
curl -fsSL "${RELEASE_BASE_URL}/appliance/${RELEASE_VERSION}/install-http-release.sh" \
  | bash -s -- --base-url "${RELEASE_BASE_URL}"
```

## 6. When To Use Which Path

- Fresh host, no Zon installed:
  Use `First Install`.
- Zon already installed, keep data and move to a newer release:
  Use `Upgrade`.
- Previous operation was interrupted or partially failed:
  Use `Clean Recovery`.
- Remove platform but preserve appliance data:
  Use `Uninstall`.
- Wipe everything and start over:
  Use `Factory Reset`, then rerun `First Install`.

## 7. Reboot / Reload Guidance

Normal Zon install, upgrade, repair, uninstall, and factory-reset flows do not
require a full host reboot.

What normally happens instead:

- `zonctl` restarts or reuses K3s as needed
- Helm is run against the local K3s API
- the bundle-local helper binaries are used from the extracted bundle

If the host itself needs a reboot because of unrelated Ubuntu package updates,
kernel maintenance, or manual system changes outside Zon, handle that as a
separate host-maintenance action, not as part of the normal appliance workflow.
