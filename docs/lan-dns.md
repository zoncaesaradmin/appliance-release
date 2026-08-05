# LAN DNS

Operator how-to for the appliance LAN DNS server: install it, add names with
`curl`, point LAN clients at it, and publish names from other appliances.

Installers (`zonctl install` / `upgrade`) never write product DNS records.
Records are added only through the DNS appliance API/UI, or through another
appliance's base-capability publish API.

This LAN DNS path is separate from host-level mDNS discovery. When
When host mDNS is enabled day-2 via Admin UI/API and Avahi or an equivalent responder is
present on the target host, clients may also reach the appliance through the
host's current `hostname.local` name.

## What You Get

| Item | Value |
| --- | --- |
| Profiles that run the DNS server | `landns`, `storage-landns`, `builder-landns`, `builder-storage-landns` |
| Zone | `appliance.internal` by default |
| Resolver listen | DNS appliance LAN IP, UDP/TCP `53` |
| Record shape | single left-hand label to A record |
| DNS records API | `GET/PUT/DELETE /api/v1/dns/records...` |
| Peer publish API | `POST /api/v1/dns/publish` on any appliance |

## 1. Set Up The DNS Appliance

1. Install a DNS-bearing profile.
2. Complete first-admin bootstrap.
3. Confirm CoreDNS is up:

```bash
sudo zonctl status --output text
sudo kubectl -n dns get deploy,pods,svc
dig @127.0.0.1 appliance.internal SOA +short
```

### Point LAN Clients At The DNS Appliance

On each client or via DHCP/router, set the DNS server to the DNS appliance LAN
IP.

Optional Ubuntu smoke check:

```bash
resolvectl dns
dig @192.168.1.105 appliance.internal SOA +short
```

## 2. Authenticate On The DNS Appliance

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

For automation, create an API token:

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
```

## 3. Manage Records On The DNS Appliance

List records:

```bash
curl -ksS \
  -H "Authorization: Bearer ${DNS_API_TOKEN}" \
  "${DNS_APPLIANCE}/api/v1/dns/records" | jq
```

Add or update `registry1.appliance.internal`:

```bash
curl -ksS \
  -X PUT \
  -H "Authorization: Bearer ${DNS_API_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{"ipv4":"192.168.1.102","ttl":300}' \
  "${DNS_APPLIANCE}/api/v1/dns/records/registry1" | jq
```

Delete it:

```bash
curl -ksS \
  -X DELETE \
  -H "Authorization: Bearer ${DNS_API_TOKEN}" \
  "${DNS_APPLIANCE}/api/v1/dns/records/registry1"
```

Prove resolution:

```bash
dig @192.168.1.105 registry1.appliance.internal A +short
```

## 4. Publish From Another Appliance

Any appliance profile exposes:

```text
POST /api/v1/dns/publish
```

One-time setup:

1. On the DNS appliance, create a token with `dns.records.register` or
   `dns.records.write`.
2. On the peer appliance, authenticate with a principal that has
   `dns.publish`.

Example:

```bash
PEER_APPLIANCE=https://192.168.1.102
DNS_APPLIANCE=https://192.168.1.105
DNS_API_TOKEN='...'

PEER_ACCESS_TOKEN="$(
  curl -ksS \
    -H 'Content-Type: application/json' \
    -d '{"username":"admin","password":"your-peer-admin-password"}' \
    "${PEER_APPLIANCE}/api/v1/auth/login" \
  | jq -r '.accessToken'
)"

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

## When To Use Which Path

- Operator or script managing the DNS box directly:
  use `PUT /api/v1/dns/records/{name}`
- Another appliance registering itself:
  use `POST /api/v1/dns/publish`
- Browser CRUD on the DNS box:
  use the `/dns` UI

Do not pass DNS publish flags to `zonctl install` or `upgrade`. DNS is API-only.
