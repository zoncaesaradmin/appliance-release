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
  "graph_api_version": "v21.0"
}
```

```sh
chmod 600 /root/channel-integration-runtime.json
sudo zonctl install \
  --bundle-dir /path/to/signed-bundle \
  --appliance-profile application-core \
  --appliance-name app \
  --dns-zone example.com \
  --channel-integration-runtime-file /root/channel-integration-runtime.json
```

For a cloud EC2 deployment, point the public DNS name and TLS SANs at the
instance (for example `app.example.com`) and forward `https://app.example.com/webhook`
to Meta. The K3s, image preload, Helm release, namespace, and service wiring are
the same as a local install. The pod has a narrowly scoped HTTPS egress rule for
the Meta Graph API; the rest of the appliance remains default-deny.
Use `public_origin: https://app.example.com` and
`tls_termination: traefik` for a direct-Traefik cloud edge; omit the Cloudflare
token file.

The installer fails closed if the capability's image is absent from the signed
bundle or if the runtime descriptor is missing or group/world readable.

## Local LAN reachability

For a local server, Cloudflare Tunnel is an optional host-native connector.
Create the tunnel and its public hostname in Cloudflare, with the tunnel
service targeting the channel route on Traefik's HTTP listener
`http://127.0.0.1:80`. Set the HTTP Host header to the external hostname
(`walocal.zonited.com` in the example below). Cloudflare terminates public TLS;
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
  --public-origin https://walocal.zonited.com \
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
  public_origin: https://walocal.zonited.com
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
  tls_termination: traefik
  bundle_transport: devhost_scp
  channel_integration_runtime_file: /Users/me/secrets/whatsapp-runtime.json
  tls_cert_file: /Users/me/secrets/app.example.com.crt
  tls_key_file: /Users/me/secrets/app.example.com.key
  tls_secret_name: capp-tls
  # Do not set cloudflare_tunnel_token_file for EC2.
```

The cloud DNS record must point `app.example.com` to the EC2 address (prefer an
Elastic IP), and the security group must permit SSH from the operator and TCP
80/443 from the intended clients. `bundle_transport: devhost_scp` makes the
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
