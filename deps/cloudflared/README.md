# cloudflared

Seeds the pinned Cloudflare Tunnel connector binary for the host-native local
LAN connector. The binary is part of the signed appliance foundation bundle,
but `zonctl install` only enables the host service when the operator supplies
`--cloudflare-tunnel-token-file`. Cloud installs omit that flag and do not run
cloudflared.

Set `TARGET_ARCH=amd64` or `TARGET_ARCH=arm64`. The seed is published through
the LAN Artifact Server files API and is never fetched by an offline build from
the public internet.
