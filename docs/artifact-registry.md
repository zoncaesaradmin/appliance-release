# Artifact Registry

This document captures the external-machine flow for using the appliance
artifact registry.

These examples assume the appliance is installed with the `storage`,
`builder`, `storage-landns`, `builder-landns`, or
`builder-storage-landns` profile and that the artifact capability is enabled.

For OCI tools, use the appliance's canonical advertised registry host (the
derived FQDN `<appliance_name>.<dns_zone>`, or a TLS SAN you configured).

If your appliance TLS certificate is not trusted yet, keep the insecure flags
shown below for quick testing. After you trust the certificate, remove `-k`,
`--tls-verify=false`, and `--insecure`.

## Release distribution via this registry

An already-running Artifact Server can also be the **release distribution**
backend for signed appliance bundles (instead of a plain HTTP file server).

In `appliance-release.config.yaml`:

```yaml
artifact_registry:
  mode: oci
  oci_registry: artifact-dns-1.appliance.internal
  oci_repository: appliance/releases
  oci_insecure: true
  oci_username: admin
  oci_token_env: APPLIANCE_DISTRIBUTION_REGISTRY_TOKEN
```

Then:

1. Create an API token on the distribution appliance (section 2 below).
2. Grant that subject `pull,push` on `appliance/releases` (or your prefix).
3. Export the token and ensure `oras` is on the build host and Mac.
4. Run the normal skill build/publish/install flow; publish pushes
   `{oci_registry}/{oci_repository}:{version}` and install pulls it.

HTTP mode (`artifact_registry.mode: http`) remains supported for labs without
a distribution appliance.

## 1. Log In And List Repositories

```bash
APPLIANCE=https://192.168.1.101
REGISTRY_HOST=192.168.1.101
USERNAME=admin
PASSWORD='your-admin-password'

ACCESS_TOKEN="$(
  curl -ksS \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"${USERNAME}\",\"password\":\"${PASSWORD}\"}" \
    "${APPLIANCE}/api/v1/auth/login" \
  | jq -r '.accessToken'
)"

curl -ksS \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "${APPLIANCE}/api/v1/registry/repositories" | jq
```

## 2. Create An API Token For Registry Use

Use the access token only for appliance API calls. Use an API token as the
password for OCI clients.

```bash
TOKEN_JSON="$(
  curl -ksS \
    -X POST \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H 'Content-Type: application/json' \
    -d '{"name":"external-registry-test","lifetimeSeconds":3600}' \
    "${APPLIANCE}/api/v1/tokens"
)"

API_TOKEN="$(jq -r '.token' <<<"${TOKEN_JSON}")"
TOKEN_ID="$(jq -r '.id' <<<"${TOKEN_JSON}")"
```

## 3. Check The Registry Challenge

```bash
curl -ksSiv "${APPLIANCE}/v2/"
```

You should see:

- `HTTP/... 401`
- a `WWW-Authenticate: Bearer ...` header

Do not use `curl -I` as the primary check. OCI clients follow the
`realm="https://.../api/v1/registry/token"` host in that header, so that
advertised host must be reachable from the client machine.

## 4. Manually Request A Registry Bearer Token

```bash
REGISTRY_TOKEN="$(
  curl -ksS --get \
    -u "${USERNAME}:${API_TOKEN}" \
    --data-urlencode service=zot \
    --data-urlencode scope='repository:demo/hello:pull,push' \
    "${APPLIANCE}/api/v1/registry/token" \
  | jq -r '.token // .access_token'
)"
```

## 5. Push And Pull A Container Image With Podman

```bash
podman login "${REGISTRY_HOST}" \
  --tls-verify=false \
  --username "${USERNAME}" \
  --password "${API_TOKEN}"

podman pull docker.io/library/busybox:1.36
podman tag docker.io/library/busybox:1.36 "${REGISTRY_HOST}/demo/busybox:1"
podman push --tls-verify=false "${REGISTRY_HOST}/demo/busybox:1"

podman pull --tls-verify=false "${REGISTRY_HOST}/demo/busybox:1"
```

## 6. Push And Pull A Generic Artifact With ORAS

```bash
printf 'hello from outside machine\n' > hello.txt

oras login "${REGISTRY_HOST}" \
  --username "${USERNAME}" \
  --password "${API_TOKEN}" \
  --insecure

oras push --insecure \
  "${REGISTRY_HOST}/demo/docs:v1" \
  hello.txt:text/plain

oras pull --insecure \
  "${REGISTRY_HOST}/demo/docs:v1" \
  -o pulled-docs
```

## 7. Inspect A Pushed Image With Skopeo

```bash
skopeo inspect \
  --tls-verify=false \
  --creds "${USERNAME}:${API_TOKEN}" \
  "docker://${REGISTRY_HOST}/demo/busybox:1"
```

## 8. Revoke The API Token When Done

```bash
curl -ksS \
  -X DELETE \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "${APPLIANCE}/api/v1/tokens/${TOKEN_ID}"
```

## Notes

- `core` should not expose this registry path at all
- `storage`, `builder`, `storage-landns`, `builder-landns`, and
  `builder-storage-landns` should expose it
- use the appliance username plus API token for registry clients
- do not use the appliance API access token directly for `podman login` or
  `oras login`
- the appliance advertises its derived FQDN
  (`<install.appliance_name>.<install.dns_zone>`) in the `/v2/` bearer
  challenge realm and `canonicalOrigin`
- clients and landns must resolve that FQDN to the appliance; install does not
  publish the A record

If you are using a DNS-bearing profile, see [lan-dns.md](lan-dns.md) to
publish the required name.
