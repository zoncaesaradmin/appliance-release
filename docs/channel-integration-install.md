# Channel integration installation

The signed `application-core` profile enables the `channel-integrations`
capability. The capability is delivered in the foundation bundle and renders
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

The installer fails closed if the capability's image is absent from the signed
bundle or if the runtime descriptor is missing or group/world readable.

## Local LAN reachability

For a local server, Cloudflare Tunnel is an optional host-native connector.
Create the tunnel and its public hostname in Cloudflare, with the tunnel
service targeting the local Traefik HTTP listener `http://127.0.0.1:80`.
Keep the token in a protected file on the target; it is never stored in the
bundle or installer state:

```sh
chmod 600 /root/cloudflared-tunnel.token
sudo zonctl install \
  --bundle-dir /path/to/signed-bundle \
  --appliance-profile application-core \
  --appliance-name app \
  --dns-zone example.com \
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
