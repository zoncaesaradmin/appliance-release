# Appliance HTTP File API

Artifact-capable appliances expose an appliance-managed HTTP file API for
signed release bundles and other simple file artifacts.

This is distinct from the OCI registry:

- File API: `https://<appliance-fqdn>/api/v1/files/...`
- OCI registry: `https://<appliance-fqdn>/v2/...`

## Model

| Item | Value |
|---|---|
| API base | `https://<appliance-fqdn>/api/v1/files/` |
| Backing host path | `/data/zon/files` |
| Capability | `files` (module) on appliance profiles that include the files module |
| Read permission | `files.read` |
| Write permission | `files.write` |
| Auth | appliance bearer token (`apt_…` API token or session access token) |

The control plane stores file content under `/data/zon/files` and serves it
through authenticated appliance routes. Upload and download use the same token
model as other appliance APIs. OCI registry access is separate and uses
`artifacts.read` / `artifacts.write` plus registry grants; do not confuse those
with file-API permissions.

## Basic Flow

1. Log in to the appliance API and obtain an access token, or create an API token.
2. Use `POST /api/v1/files/<path>` to upload.
3. Use `GET /api/v1/files/<path>` to download.

## Get A Bearer Token

Preferred: open the distributor appliance UI → user menu → **Manage API keys**,
create a long-lived token (omit scopes so it inherits your role permissions —
needed for both OCI seed pushes and `/api/v1/files` uploads), copy the `apt_…`
secret once, and export it as `DEV_REGISTRY_TOKEN` (preferred). Optional config
override:

```yaml
bundle_store:
  mode: appliance_files
  base_url: https://artifact-dns-1.appliance.internal/api/v1/files
  # access_token: apt_….…   # optional; prefer DEV_REGISTRY_TOKEN
```

You can also mint a token with curl (then `export DEV_REGISTRY_TOKEN=...`).
Omit `scopes` (or set only what you need). For release/seed hosts that push
both OCI and files, omit scopes or include both families:

```bash
APPLIANCE=https://artifact-dns-1.appliance.internal
USERNAME=admin
PASSWORD='your-password'

ACCESS_TOKEN="$(
  curl -ksS \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"${USERNAME}\",\"password\":\"${PASSWORD}\"}" \
    "${APPLIANCE}/api/v1/auth/login" \
  | jq -r '.accessToken'
)"

API_TOKEN="$(
  curl -ksS \
    -X POST \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H 'Content-Type: application/json' \
    -d '{"name":"appliance-release-files","lifetimeSeconds":31536000}' \
    "${APPLIANCE}/api/v1/tokens" \
  | jq -r '.token'
)"
echo "${API_TOKEN}"
```

If you must scope the token, file uploads require `files.write` (and usually
`files.read`). Artifact-only scopes such as `artifacts.read` /
`artifacts.write` authorize OCI registry use but return **HTTP 403** on
`/api/v1/files`.
## Upload A File

Small files may use either form. Prefer `-T` (stream from disk) for any
non-trivial payload — `--data-binary @file` loads the whole file into memory
and will OOM on multi-GB release bundles.

```bash
curl -ksS \
  -X POST \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H 'Content-Type: application/octet-stream' \
  -T ./hello.txt \
  "${APPLIANCE}/api/v1/files/shared/hello.txt"
```

Example response:

```json
{"path":"shared/hello.txt","size":18,"overwritten":false}
```

If you upload to the same path again, the appliance overwrites that file path
atomically and returns `overwritten: true`.

## Download A File

Prefer HTTP/1.1 for large files (multi-GB appliance bundles). Traefik HTTP/2
can abort mid-stream with `curl: (92) PROTOCOL_ERROR`.

```bash
curl -ksS --http1.1 \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -o /tmp/hello.txt \
  "${APPLIANCE}/api/v1/files/shared/hello.txt"
```

## Release Bundle Example

Suggested layout:

```text
api/v1/files/appliance/<version>/
  appliance-<version>-foundation.tar.gz
  appliance-<version>-developer.tar.gz   # when built (APPLIANCE_PACKS)
  appliance-<version>-inference.tar.gz   # when built
  release-index.yaml
  release-signing.pub
  sha256sum.txt
  install-release.sh
```

Upload the standard release bundle files (always stream with `-T`):

```bash
VERSION=0.1.0
BASE="${APPLIANCE}/api/v1/files/appliance/${VERSION}"

curl -ksS -X POST -H "Authorization: Bearer ${ACCESS_TOKEN}" -H 'Content-Type: application/octet-stream' \
  -T "./appliance-${VERSION}-foundation.tar.gz" "${BASE}/appliance-${VERSION}-foundation.tar.gz"
curl -ksS -X POST -H "Authorization: Bearer ${ACCESS_TOKEN}" -H 'Content-Type: application/octet-stream' \
  -T ./release-signing.pub "${BASE}/release-signing.pub"
curl -ksS -X POST -H "Authorization: Bearer ${ACCESS_TOKEN}" -H 'Content-Type: application/octet-stream' \
  -T ./sha256sum.txt "${BASE}/sha256sum.txt"
curl -ksS -X POST -H "Authorization: Bearer ${ACCESS_TOKEN}" -H 'Content-Type: application/octet-stream' \
  -T ./install-release.sh "${BASE}/install-release.sh"
```

Download the helper:

```bash
curl -ksS \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "${BASE}/install-release.sh"
```

## Notes

- The appliance creates parent directories under `/data/zon/files` as needed.
- Host path ownership is `10001:20000` with mode `2775` (setgid, group-writable,
  host-user readable/traversable) so the control plane can upload via the
  authenticated files API and host users can inspect the tree like service
  logs. Uploaded files are mode `0644`. There is no Traefik `/files` nginx
  surface; use `/api/v1/files` only.
- Directory listing is not provided; clients must know the full path.
- Use the release scripts in `appliance-release` if you want the automated
  build-host publish and target-install flow.

## Related

- Registry usage for OCI images and ORAS artifacts:
  [artifact-registry.md](artifact-registry.md)
- Release skill config:
  [.agents/skills/release/references/config.example.yaml](../.agents/skills/release/references/config.example.yaml)
