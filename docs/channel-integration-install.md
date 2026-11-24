# Channel integration installation

The signed `application-core` profile enables the `channel-integrations`
capability. The capability is delivered in the app-stack bundle and renders
one `channel-integration` Deployment and ClusterIP Service in `ace-apps`.

The adapter is optional at runtime, but its protected Meta/WhatsApp descriptor
is required for an `application-core` install. Prepare it on the target host;
do not put it in Git, the release bundle, shell history, or support bundles:

```json
{
  "verify_token": "...",
  "app_secret": "...",
  "graph_access_token": "...",
  "phone_number_id": "1234567890",
  "graph_api_version": "v21.0",
  "tenant_id": "zonited-solutions",
  "channel_id": "customer-whatsapp"
}
```

`tenant_id` and `channel_id` are provider-neutral application identity
bindings. They are optional for the first customer endpoint and default to
`zonited-solutions` and `customer-whatsapp`; use a distinct stable channel ID for each
additional platform number after that channel has been provisioned in the
identity store. The adapter verifies Meta's signature first, then resolves the
sender through the internal identity contract. It never forwards a WhatsApp
sender or caller-supplied identity headers to application APIs.

For a customer message, the identity response includes a short-lived discovery
link bound to that channel sender. The adapter replies with that link so the
person can open `/app/discover`, share browser location, see up to five public
zones within 10 km, and submit a pending join request. A WhatsApp location
message is accepted as a normal inbound event, but the browser discovery flow
remains the authoritative location submission. A login is required before the
join request is submitted, and the submitted location must be within the
Zonity's join radius (1 km by default). A Zonity admin reviews the request;
when no admin exists, the no-admin policy may auto-approve it. If no zone
is nearby, the signed-in user can request a new Zonity by name. That request is
reviewed and created only by authorized tenant operators or platform operators.

```sh
chmod 600 /root/channel-integration-runtime.json
sudo zonctl install \
  --bundle-dir /path/to/signed-bundle \
  --appliance-profile application-core \
  --appliance-name app \
  --dns-zone example.com \
  --channel-integration-runtime-file /root/channel-integration-runtime.json
```

For a cloud EC2 deployment, point the application and channel DNS names at the
same instance (for example `app.example.com` and `channels.example.com`) and
forward `https://channels.example.com/webhook` to Meta. The K3s, image preload,
Helm release, namespace, and service wiring are
the same as a local install. The pod has a narrowly scoped HTTPS egress rule for
the Meta Graph API; the rest of the appliance remains default-deny.
Use `public_origin: https://app.example.com`,
`channel_integration_origin: https://channels.example.com`, and
`tls_termination: traefik` for a direct-Traefik cloud edge; omit the Cloudflare
token file. The separate channel origin is optional and is shown here only for
the cloud split-host deployment.

The installer fails closed if the capability's image is absent from the signed
bundle or if the runtime descriptor is missing or group/world readable.
When application identity is enabled, the installer also creates the
target-local internal identity key and injects it only into the identity and
channel-integration pods; it is not a runtime-file field and must not be added
to the WhatsApp JSON.

## Local LAN reachability

For a local server, Cloudflare Tunnel is an optional host-native connector.
Create the tunnel and its public hostnames in Cloudflare, with both ingress
rules targeting Traefik's HTTP listener at `http://127.0.0.1:80`. Preserve the
HTTP Host header for each external hostname (`local.app.zonited.com` and
`local.channels.zonited.com` in the example below).
Cloudflare terminates public TLS;
the channel route is therefore HTTP-only on the appliance. In
`tls_termination: cloudflare` mode the main UI/API route is also published on
Traefik's local `web` entrypoint, so the public root and `/app/login` (or
`/console/login` for operator profiles) work through the same tunnel. This does
not enable the `plaintext-http` capability: application cookies remain Secure
because the browser-facing origin is still HTTPS. Kubernetes rejects
loopback values in a Service `externalIPs` field, so `zonctl` keeps the
Cloudflare origin at `http://127.0.0.1:80` and installs a release-owned,
cloudflared-only host redirect to the current K3s ServiceLB pod.
Keep the token in a protected file on the target; it is never stored in the
bundle or installer state:

```sh
chmod 600 /root/cloudflared-tunnel.token
sudo zonctl install \
  --bundle-dir /path/to/signed-bundle \
  --appliance-profile application-core \
  --appliance-name app \
  --dns-zone example.com \
  --public-origin https://local.app.zonited.com \
  --channel-integration-origin https://local.channels.zonited.com \
  --tls-termination cloudflare \
  --channel-integration-runtime-file /root/channel-integration-runtime.json \
  --cloudflare-tunnel-token-file /root/cloudflared-tunnel.token
```

This installs the pinned `cloudflared` binary from the signed foundation
bundle and enables `zon-cloudflared.service`. Omit
`--cloudflare-tunnel-token-file` for EC2/cloud installs; no Cloudflare host
service is installed there, and the cloud deployment uses direct Traefik TLS.

Cloudflare Tunnel is intentionally not a separate catalog capability: it is an
optional host transport for `channel-integrations`. Supplying its token for a
profile without that capability is rejected by the installer.

## Three-YAML release runner

For `run-release-from-devhost.sh`, select `application-core` in the install
YAML and point the two optional settings at protected files on the devhost:

```yaml
install:
  appliance_profile: application-core
  public_origin: https://local.app.zonited.com
  channel_integration_origin: https://local.channels.zonited.com
  tls_termination: cloudflare
  channel_integration_runtime_file: /absolute/path/channel-integration-runtime.json
  # Local LAN only; omit for EC2/cloud:
  # cloudflare_tunnel_token_file: /absolute/path/cloudflare-tunnel.token
```

The build/publish YAML must publish both `foundation` and `app-stack` (or use
`all`). The `application-core` profile maps its application capabilities to the
`app-stack` pack, so the installer downloads that optional pack automatically.
The runner copies the protected
files to the target only for finalization, passes their paths and external
origin settings to `zonctl`, and removes the temporary target copies afterward.

## Cloud EC2 release runner

Cloud installation uses the same signed-bundle runner. There is no separate
connected `prepare-environment.sh` or application downloader: the runner
builds/publishes the signed bundle, prepares K3s on the EC2 host, preloads the
bundle, and finalizes the Helm release in one workflow.

Use the same command as a LAN install, with a cloud target alias and a cloud
install file:

```sh
bash .agents/skills/release/scripts/run-release-from-devhost.sh \
  --config "$HOME/ec2-devhost.yaml" \
  --build-publish-config "$HOME/ec2-build-publish.yaml" \
  --install-config "$HOME/ec2-install.yaml"
```

The cloud install file differs only in the edge settings:

```yaml
install:
  bootstrap_admin: true
  enable_default_license: true
  appliance_name: app
  dns_zone: example.com
  appliance_profile: application-core
  public_origin: https://app.example.com
  channel_integration_origin: https://channels.example.com
  tls_termination: traefik
  bundle_transport: devhost_scp
  channel_integration_runtime_file: /Users/me/secrets/whatsapp-runtime.json
  tls_cert_file: /Users/me/secrets/app-and-channels.example.com.crt
  tls_key_file: /Users/me/secrets/app-and-channels.example.com.key
  tls_secret_name: capp-tls
  # Do not set cloudflare_tunnel_token_file for EC2.
```

The cloud DNS records must point both `app.example.com` and
`channels.example.com` to the EC2 address (prefer an Elastic IP), and the
security group must permit SSH from the operator and TCP 80/443 from the
intended clients. The certificate supplied to Traefik must cover both names
(or use a wildcard). `bundle_transport: devhost_scp` makes the
release runner copy the already-validated signed export from the devhost to a
run-specific temporary directory on EC2. The target installs from that local
`file://` copy, and the coordinator removes it after stage/finalize (including
failure cleanup), including the helper's temporary download/extraction work
directory. This avoids requiring EC2 to reach the LAN Artifact Server;
bundle signature and checksum verification are unchanged. Omit the setting to
use the normal configured signed-bundle distributor. `tls_termination: traefik`
means Traefik terminates HTTPS directly on the instance. Cloudflare Tunnel is
local-LAN-only and is not installed in this mode.

The EC2 SSH alias may be its public address. The runner discovers the
instance's private/local IPv4 address over SSH and uses that address for the
embedded-etcd inventory and K3s node identity; the public address remains an
external SSH/TLS endpoint only.

For direct Traefik TLS, `tls_cert_file`, `tls_key_file`, and (optionally)
`tls_secret_name` are the appliance equivalents of `CAPP_TLS_CERT_FILE`,
`CAPP_TLS_KEY_FILE`, and `CAPP_TLS_SECRET`. The files remain on the devhost,
are copied only for finalization, and are removed from the target afterward.
`additional_tls_sans_csv` is separate: it adds SANs to installer-generated
appliance/K3s certificates but never modifies the supplied public certificate.
It can be omitted for a normal cloud hostname when the supplied certificate
covers that hostname; retain it only for additional internal or K3s API names.
The appliance still creates its internal `appliance-ca` for control-plane trust.
