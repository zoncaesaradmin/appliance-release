# LAN DNS Appliance Usage

Operator how-to for the appliance LAN DNS server: install it, add names with
`curl`, point LAN clients at it, and publish names from other appliances.

Installers (`zonctl install` / `upgrade`) never write product DNS records.
Records are added only through the DNS appliance API/UI, or through another
appliance's base-capability publish API.

## What you get

| Item | Value |
|---|---|
| Profiles that run the DNS server | `landns`, `storage-landns`, `builder-landns`, `builder-storage-landns` |
| Zone | `appliance.internal` (not `.local` — Ubuntu treats that as mDNS) |
| Resolver listen | DNS appliance LAN IP, UDP/TCP **53** |
| Record shape | single left-hand label → A record, e.g. `registry1` → `registry1.appliance.internal` |
| DNS records API (dns capability) | `GET/PUT/DELETE /api/v1/dns/records…` |
| Peer publish API (base capability) | `POST /api/v1/dns/publish` on **any** appliance |

Example topology used below:

```text
DNS appliance:   https://192.168.1.105   (profile landns)
Peer appliance:  https://192.168.1.102   (profile core / builder / …)
```

Replace those addresses with yours. Keep `-k` only while the appliance TLS
certificate is not trusted yet.

---

## 1. Set up the DNS appliance

1. Install a bundle with a DNS-bearing profile (`landns`, `storage-landns`, `builder-landns`, or `builder-storage-landns`)
   (see [target-host-operations.md](target-host-operations.md)).
2. Complete first-admin bootstrap on that host.
3. Confirm CoreDNS is up:

```bash
sudo zonctl status --output text
sudo kubectl -n dns get deploy,pods,svc
dig @127.0.0.1 appliance.internal SOA +short
```

You should see SOA data for `appliance.internal`. Product A records are empty
until you add them via API/UI.

### Point LAN clients at the DNS appliance

On each client (or via DHCP/router), set the DNS server to the DNS appliance
LAN IP, for example `192.168.1.105`.

Optional Ubuntu smoke check on a client:

```bash
resolvectl dns
dig @192.168.1.105 appliance.internal SOA +short
```

---

## 2. Authenticate on the DNS appliance

```bash
DNS_APPLIANCE=https://192.168.1.105
USERNAME=admin
PASSWORD='your-admin-password'

ACCESS_TOKEN="$(
  curl -ksS \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"${USERNAME}\",\"password\":\"${PASSWORD}\"}" \
    "${DNS_APPLIANCE}/api/v1/auth/login" \
  | jq -r '.accessToken'
)"
```

Session access tokens are short-lived. For automation, create an API token:

```bash
TOKEN_JSON="$(
  curl -ksS \
    -X POST \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H 'Content-Type: application/json' \
    -d '{"name":"landns-admin","lifetimeSeconds":7776000}' \
    "${DNS_APPLIANCE}/api/v1/tokens"
)"

DNS_API_TOKEN="$(jq -r '.token' <<<"${TOKEN_JSON}")"
echo "DNS API token id: $(jq -r '.id' <<<"${TOKEN_JSON}")"
# Save DNS_API_TOKEN somewhere safe; it is shown only once.
```

Permissions:

| Goal | Permission on DNS appliance | Typical role |
|---|---|---|
| List records | `dns.records.read` | Administrator, Viewer |
| Create/update/delete any record | `dns.records.write` | Administrator |
| Peer register/renew owned names | `dns.records.register` | Administrator, Automation |

Admin writes use TTL default **300** when omitted. Peer registration uses TTL
default **60** and a **15-minute** lease that must be renewed.

TTL is the **client cache** lifetime for an answer, not how long the DNS
appliance takes to publish a change. After an admin add/update/delete, the
appliance bumps the zone SOA serial and CoreDNS reloads the zone file about
every **1 second**, so LAN clients that query the DNS appliance directly
should see the new answer within roughly **1–2 seconds** (plus any prior
NXDOMAIN cached for ~1s). Clients must use the DNS appliance as their
resolver; a public resolver such as `8.8.8.8` will never learn
`*.appliance.internal`.

### Browser UI on the DNS appliance

After first-admin setup, sign in to the DNS appliance. Profiles with the
`dns` capability show a **DNS** nav link and a dashboard callout.

On `/dns`:

- the table lists every stored A record (admin, peer, and optional bootstrap)
- Administrators (`dns.records.write`) can add/update a name→IPv4 mapping
  in the form under the list, edit a row, or delete it
- Viewers (`dns.records.read` only) see the list read-only

---

## 3. Manage records on the DNS appliance (direct API)

Use these when you are talking **to the DNS appliance itself**.

### List records

```bash
curl -ksS \
  -H "Authorization: Bearer ${DNS_API_TOKEN}" \
  "${DNS_APPLIANCE}/api/v1/dns/records" | jq
```

Example response:

```json
{
  "zone": "appliance.internal",
  "items": [
    {
      "name": "registry1",
      "fqdn": "registry1.appliance.internal",
      "ipv4": "192.168.1.102",
      "ttl": 300,
      "source": "admin",
      "owner": "",
      "createdAt": "…",
      "updatedAt": "…"
    }
  ]
}
```

### Add or update an A record

`name` is only the left-hand label (`registry1`), not the FQDN.

```bash
curl -ksS \
  -X PUT \
  -H "Authorization: Bearer ${DNS_API_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{"ipv4":"192.168.1.102","ttl":300}' \
  "${DNS_APPLIANCE}/api/v1/dns/records/registry1" | jq
```

That creates/updates `registry1.appliance.internal` → `192.168.1.102`.

### Delete a record

```bash
curl -ksS \
  -X DELETE \
  -H "Authorization: Bearer ${DNS_API_TOKEN}" \
  "${DNS_APPLIANCE}/api/v1/dns/records/registry1"
```

Expect HTTP `204`.

### Prove resolution

```bash
dig @192.168.1.105 registry1.appliance.internal A +short
# expect: 192.168.1.102
```

---

## 4. Publish from another appliance (core / base capability API)

Any appliance profile exposes:

```http
POST /api/v1/dns/publish
```

Permission on the **peer** appliance: `dns.publish`
(Administrator and Automation have it).

That peer control plane then calls the remote DNS appliance:

```http
PUT /api/v1/dns/records/{name}
```

using the DNS API token you supply in the body.

### One-time tokens

1. On the **DNS appliance**, create a token whose user has
   `dns.records.register` or `dns.records.write` (section 2).
   That token is `DNS_API_TOKEN` below.
2. On the **peer appliance**, log in and create a local token with
   `dns.publish` (Administrator / Automation), or use a session
   access token for a quick test.

```bash
PEER_APPLIANCE=https://192.168.1.102
DNS_APPLIANCE=https://192.168.1.105
DNS_API_TOKEN='…token from DNS appliance…'

PEER_ACCESS_TOKEN="$(
  curl -ksS \
    -H 'Content-Type: application/json' \
    -d '{"username":"admin","password":"your-peer-admin-password"}' \
    "${PEER_APPLIANCE}/api/v1/auth/login" \
  | jq -r '.accessToken'
)"
```

### Publish this host's name/IP

```bash
curl -ksS \
  -X POST \
  -H "Authorization: Bearer ${PEER_ACCESS_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d "{
    \"dnsApplianceURL\": \"${DNS_APPLIANCE}\",
    \"apiToken\": \"${DNS_API_TOKEN}\",
    \"name\": \"registry1\",
    \"ipv4\": \"192.168.1.102\",
    \"ttl\": 60
  }" \
  "${PEER_APPLIANCE}/api/v1/dns/publish" | jq
```

Expected:

```json
{
  "name": "registry1",
  "ipv4": "192.168.1.102"
}
```

Then resolve through the DNS appliance:

```bash
dig @192.168.1.105 registry1.appliance.internal A +short
```

### Body fields

| Field | Required | Notes |
|---|---|---|
| `dnsApplianceURL` | yes | Base URL of the DNS appliance, e.g. `https://192.168.1.105` |
| `apiToken` | yes | Bearer token **on the DNS appliance** with `dns.records.register` or `dns.records.write` |
| `name` | yes | Single DNS label (`registry1`), not an FQDN |
| `ipv4` | yes | IPv4 address to publish |
| `ttl` | no | Defaults to 60 for peer-style publish |
| `owner` | no | Defaults to the authenticated peer principal; peer-register tokens may only own their own names |

### When to use which path

| Situation | Use |
|---|---|
| Operator / script managing the DNS box directly | Section 3: `PUT /api/v1/dns/records/{name}` on the DNS appliance |
| Another appliance registering itself | Section 4: `POST /api/v1/dns/publish` on the peer appliance |
| Browser CRUD on the DNS box | UI `/dns` |

Do **not** pass DNS publish flags to `zonctl install` / `upgrade`. Those
flags are not supported; DNS is API-only.

---

## 5. Quick checklist

1. Install a DNS-bearing profile (`landns`, `storage-landns`, `builder-landns`, or `builder-storage-landns`).
2. Bootstrap admin; create `DNS_API_TOKEN`.
3. Point LAN resolvers at the DNS appliance IP `:53`.
4. Add names with `PUT /api/v1/dns/records/{name}` **or** peer
   `POST /api/v1/dns/publish`.
5. `dig @<dns-ip> <name>.appliance.internal A +short`.

OpenAPI reference: `appliance-code` `docs/openapi/control-plane-v1.yaml`
(`/api/v1/dns/records` and `/api/v1/dns/publish`).
