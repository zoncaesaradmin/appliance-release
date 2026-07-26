# Appliance HTTP File Server

Artifact-capable appliances (profiles such as `storage`, `storage-landns`,
`builder`, `builder-landns`, `builder-storage-landns`) expose a generic static
HTTP file server next to the OCI Artifact Registry.

| Item | Value |
|---|---|
| URL prefix | `https://<appliance-fqdn>/files/` |
| Host data path | `/data/zon/files` |
| Kubernetes namespace | `artifacts` |
| Deployment | `fileserver` |
| Auth (v1) | none — treat as LAN-trusted |
| Directory listing | disabled — clients must know the exact path |

This is **not** the OCI registry (`/v2`). Container images still use zot and
tokens as described in [artifact-registry.md](artifact-registry.md).

There is also **no control-plane JSON API** to upload or delete files today.
“Push” means writing into the host directory; “pull” means HTTP GET.

## Prerequisites

- Appliance installed with an artifact-capable profile
- Pods up:

  ```bash
  sudo kubectl -n artifacts get deploy,pods
  # expect Deployment/fileserver Available
  ```

- Base URL (examples below use the derived FQDN; IP + TLS SAN also works):

  ```bash
  APPLIANCE=https://artifact-dns-1.appliance.internal
  # or: APPLIANCE=https://192.168.1.101
  ```

If the appliance TLS certificate is not trusted yet, use `curl -k` (shown
below). Remove `-k` after you trust the cert.

## Layout

Anything under `/data/zon/files` on the appliance host is served under
`/files/` with the same relative path:

```text
Host path                                         URL
/data/zon/files/hello.txt                         $APPLIANCE/files/hello.txt
/data/zon/files/appliance/0.1.0/bundle.tar.gz     $APPLIANCE/files/appliance/0.1.0/bundle.tar.gz
/data/zon/files/shared/notes/readme.md            $APPLIANCE/files/shared/notes/readme.md
```

Suggested convention for signed appliance release packages:

```text
/data/zon/files/appliance/<version>/
  appliance-<version>-bundle.tar.gz
  release-signing.pub
  sha256sum.txt
  install-http-release.sh
```

## Push (add or update files)

Write on the **appliance host** into `/data/zon/files`. The fileserver pod
mounts that path read-only, so uploads never go through Traefik or a REST API.

### From another machine (scp / rsync)

```bash
APPLIANCE_HOST=zonsys@192.168.1.101
VERSION=0.1.0
REMOTE_DIR=/data/zon/files/appliance/${VERSION}

ssh "${APPLIANCE_HOST}" "sudo mkdir -p '${REMOTE_DIR}' && sudo chown -R 10005:20000 /data/zon/files && sudo chmod 2755 /data/zon/files"

# copy one file
scp ./hello.txt "${APPLIANCE_HOST}:/tmp/hello.txt"
ssh "${APPLIANCE_HOST}" "sudo mv /tmp/hello.txt /data/zon/files/hello.txt && sudo chown 10005:20000 /data/zon/files/hello.txt"

# or a whole release tree
rsync -av --rsync-path='sudo rsync' \
  ./export/appliance-${VERSION}/ \
  "${APPLIANCE_HOST}:${REMOTE_DIR}/"
ssh "${APPLIANCE_HOST}" "sudo chown -R 10005:20000 '${REMOTE_DIR}'"
```

UID `10005` / GID `20000` match the fileserver pod identity that zonctl
prepares at install. Files must be readable by that UID (or world-readable).

### On the appliance host directly

```bash
sudo mkdir -p /data/zon/files/shared
printf 'hello from the appliance\n' | sudo tee /data/zon/files/shared/hello.txt >/dev/null
sudo chown -R 10005:20000 /data/zon/files
sudo chmod 2755 /data/zon/files
```

### Ownership quick check

```bash
sudo ls -la /data/zon/files
sudo kubectl -n artifacts get deploy fileserver
```

## Pull (download over HTTP)

```bash
APPLIANCE=https://artifact-dns-1.appliance.internal

# HEAD / existence check
curl -kfsSI "${APPLIANCE}/files/shared/hello.txt"

# download
curl -kfLo /tmp/hello.txt "${APPLIANCE}/files/shared/hello.txt"
cat /tmp/hello.txt

# download a release package tree entry
VERSION=0.1.0
curl -kfLo "/tmp/appliance-${VERSION}-bundle.tar.gz" \
  "${APPLIANCE}/files/appliance/${VERSION}/appliance-${VERSION}-bundle.tar.gz"
```

Notes:

- `GET /files` redirects to `/files/`.
- Missing paths return HTTP 404 (not a directory listing).
- No auth headers are required in v1.

## Example: publish a signed release for target install

On the build/publish side, stage the export files into the appliance hostPath,
then point install config at the fileserver base URL:

```yaml
# appliance-release.config.yaml (excerpt)
artifact_registry:
  mode: fileserver
  base_url: https://artifact-dns-1.appliance.internal/files
  release_path_prefix: appliance
```

Manual publish (until automated skill publish lands):

```bash
VERSION=0.1.0
HOST=zonsys@192.168.1.101
SRC=/path/to/export   # contains appliance-$VERSION-bundle.tar.gz, release-signing.pub, …

ssh "${HOST}" "sudo mkdir -p /data/zon/files/appliance/${VERSION}"
scp \
  "${SRC}/appliance-${VERSION}-bundle.tar.gz" \
  "${SRC}/release-signing.pub" \
  "${SRC}/sha256sum.txt" \
  "${SRC}/install-http-release.sh" \
  "${HOST}:/tmp/"
ssh "${HOST}" "sudo mv /tmp/appliance-${VERSION}-bundle.tar.gz /tmp/release-signing.pub /tmp/sha256sum.txt /tmp/install-http-release.sh \
  /data/zon/files/appliance/${VERSION}/ && sudo chown -R 10005:20000 /data/zon/files/appliance/${VERSION}"
```

Target (or skill `install-on-target`) then curls:

```text
https://artifact-dns-1.appliance.internal/files/appliance/0.1.0/...
```

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Connection refused / TLS errors | Wrong host, Traefik not ready, or untrusted cert (`curl -k` for lab) |
| HTTP 404 | File missing under `/data/zon/files/...`, or path typo (listing is off) |
| HTTP 403 / empty body after upload | File not readable by UID 10005 |
| Pod not Available | `sudo kubectl -n artifacts describe deploy/fileserver` and pod logs |
| Hits UI HTML instead of file | Wrong path (must start with `/files/`); API is `/api/v1`, OCI is `/v2` |

```bash
# pod status
sudo kubectl -n artifacts get pods -l app.kubernetes.io/component=fileserver
sudo kubectl -n artifacts logs deploy/fileserver --tail=50

# host tree
sudo find /data/zon/files -type f | head
```

## Related

- OCI Artifact Registry (images/ORAS): [artifact-registry.md](artifact-registry.md)
- Release skill config (`artifact_registry.mode: fileserver`):
  [.agents/skills/release/references/config.example.yaml](../.agents/skills/release/references/config.example.yaml)
