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
| Capability | `artifact` |
| Read permission | `artifacts.read` |
| Write permission | `artifacts.write` |
| Auth | appliance bearer token |

The control plane stores file content under `/data/zon/files` and serves it
through authenticated appliance routes. Upload and download use the same token
model as other appliance APIs.

## Basic Flow

1. Log in to the appliance API and obtain an access token, or create an API token.
2. Use `POST /api/v1/files/<path>` to upload.
3. Use `GET /api/v1/files/<path>` to download.

## Get A Bearer Token

Preferred: open the distributor appliance UI → **Dashboard → API tokens**, create a
long-lived token (scopes “Artifact files only” for release publish, or all
permissions), copy the `apt_…` secret once, and export it as
`DEV_REGISTRY_TOKEN` (preferred). Optional config override:

```yaml
bundle_store:
  mode: appliance_files
  base_url: https://artifact-dns-1.appliance.internal/api/v1/files
  # access_token: apt_….…   # optional; prefer DEV_REGISTRY_TOKEN
```

You can also mint a token with curl (then `export DEV_REGISTRY_TOKEN=...`):

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
    -d '{"name":"appliance-release-files","lifetimeSeconds":31536000,"scopes":["artifacts.read","artifacts.write"]}' \
    "${APPLIANCE}/api/v1/tokens" \
  | jq -r '.token'
)"
echo "${API_TOKEN}"
```

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

```bash
curl -ksS \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -o /tmp/hello.txt \
  "${APPLIANCE}/api/v1/files/shared/hello.txt"
```

## Release Bundle Example

Suggested layout:

```text
api/v1/files/appliance/<version>/
  appliance-<version>-bundle.tar.gz
  release-signing.pub
  sha256sum.txt
  install-http-release.sh
```

Upload the standard release bundle files (always stream with `-T`):

```bash
VERSION=0.1.0
BASE="${APPLIANCE}/api/v1/files/appliance/${VERSION}"

curl -ksS -X POST -H "Authorization: Bearer ${ACCESS_TOKEN}" -H 'Content-Type: application/octet-stream' \
  -T "./appliance-${VERSION}-bundle.tar.gz" "${BASE}/appliance-${VERSION}-bundle.tar.gz"
curl -ksS -X POST -H "Authorization: Bearer ${ACCESS_TOKEN}" -H 'Content-Type: application/octet-stream' \
  -T ./release-signing.pub "${BASE}/release-signing.pub"
curl -ksS -X POST -H "Authorization: Bearer ${ACCESS_TOKEN}" -H 'Content-Type: application/octet-stream' \
  -T ./sha256sum.txt "${BASE}/sha256sum.txt"
curl -ksS -X POST -H "Authorization: Bearer ${ACCESS_TOKEN}" -H 'Content-Type: application/octet-stream' \
  -T ./install-http-release.sh "${BASE}/install-http-release.sh"
```

Download the helper:

```bash
curl -ksS \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "${BASE}/install-http-release.sh"
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
