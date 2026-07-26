# External Artifact Server Trial Usage

This document captures a simple trial flow for using the appliance artifact
server from a different machine.

The example appliance address below is:

```text
https://192.168.1.101
```

That exact IP is fine to use if the client machine can reach the appliance at
that address. If your appliance is reachable at a different hostname or IP,
replace it consistently in the commands below.

These examples assume the appliance is installed with the `storage`,
`builder`, `storage-landns`, `builder-landns`, or `builder-storage-landns` profile and that the artifact capability is
enabled.

For OCI tools, use the appliance's canonical advertised registry host. In a
healthy setup this should match the host or IP you intentionally configured as
the appliance public host at install time.

If your appliance TLS certificate is not trusted yet, keep the insecure flags
shown below for quick testing. After you trust the certificate, remove `-k`,
`--tls-verify=false`, and `--insecure`.

## 1. Log in and list repositories

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

## 2. Create an API token for registry use

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

echo "token id: ${TOKEN_ID}"
```

## 3. Check that the registry challenge is live

```bash
curl -ksSiv "${APPLIANCE}/v2/"
```

You should see:

- `HTTP/... 401`
- a `WWW-Authenticate: Bearer ...` header

Do not use `curl -I` here as the primary check. `-I` sends `HEAD /v2/`, and a
`405` there does not prove the registry bearer challenge is correct. The
important check is `GET /v2/` returning `401`.

Also inspect the `realm="https://.../api/v1/registry/token"` value in the
`WWW-Authenticate` header. OCI clients such as Podman, ORAS, and Skopeo follow
that advertised realm host when they fetch registry tokens.

That means the advertised realm host must be reachable from the client machine.
If `/v2/` is opened through `https://192.168.1.101` but the bearer realm says
`https://zonsyssrv1/api/v1/registry/token`, then Podman/ORAS will try to reach
`zonsyssrv1`, not `192.168.1.101`.

## 4. Manually request a registry bearer token

This is useful to understand the auth flow directly.

```bash
REGISTRY_TOKEN="$(
  curl -ksS --get \
    -u "${USERNAME}:${API_TOKEN}" \
    --data-urlencode service=zot \
    --data-urlencode scope='repository:demo/hello:pull,push' \
    "${APPLIANCE}/api/v1/registry/token" \
  | jq -r '.token // .access_token'
)"

echo "${REGISTRY_TOKEN}" | cut -c1-60
```

## 5. Use raw registry HTTP with that bearer token

```bash
curl -ksS \
  -H "Authorization: Bearer ${REGISTRY_TOKEN}" \
  "${APPLIANCE}/v2/demo/hello/tags/list"
```

If the repo does not exist yet, you will usually get a not-found style
response rather than an auth failure.

## 6. Push and pull a container image with Podman

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

## 7. Push and pull a generic artifact with ORAS

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

## 8. Inspect a pushed image with Skopeo

```bash
  skopeo inspect \
  --tls-verify=false \
  --creds "${USERNAME}:${API_TOKEN}" \
  "docker://${REGISTRY_HOST}/demo/busybox:1"
```

## 9. Revoke the API token when done

```bash
curl -ksS \
  -X DELETE \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "${APPLIANCE}/api/v1/tokens/${TOKEN_ID}"
```

## Notes

- `core` profile should not expose this registry path at all.
- `storage`, `builder`, `storage-landns`, `builder-landns`, and `builder-storage-landns` profiles should expose it.
- Use the appliance username plus API token for registry clients.
- Use the appliance API access token only for `/api/v1/...` API calls.
- Do not use the appliance API access token directly for `podman login` or
  `oras login`.
- For OCI client compatibility, the appliance must advertise a client-reachable
  public host or IP in the `/v2/` bearer challenge realm.
- A practical external setup should choose one canonical public identity for
  registry auth, and that identity should be resolvable/reachable by every
  client machine.
- Install-time recommendation:
  set `install.public_host` in the release config to the one client-reachable
  identity you want the appliance to advertise in `canonicalOrigin` and the
  registry bearer realm.
- If you want clients to start with either hostname or IP, add the other form
  as an extra TLS SAN with `--tls-san` or `install.additional_tls_sans_csv`.
- If you do not have real DNS for the hostname, prefer using the appliance IP
  as `public_host`. That avoids clients being redirected to a hostname they
  cannot resolve during registry authentication.
- After you inspect `GET /v2/`, set `REGISTRY_HOST` to the same canonical host
  family you want OCI tools to use consistently for login, push, and pull.
- Even when the certificate is valid for both DNS and IP, OCI auth still
  follows one canonical advertised realm host. In practice, each client flow
  should consistently succeed against the advertised host, while direct manual
  tests like `curl https://<ip>/v2/` can still validate the alternate SAN.
