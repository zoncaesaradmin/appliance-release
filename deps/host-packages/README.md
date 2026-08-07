# host-packages

Builds the Ubuntu host .deb payload (mdns + wifi-ap) via appliance-code
`export-host-packages.sh`, archives it, and uploads to the files API:

`/api/v1/files/host-packages/ubuntu-24.04/<fingerprint>/host-packages.tar.zst`

Requires an Ubuntu 24.04 environment and `APPLIANCE_CODE_DIR` (or a sibling
`../appliance-code` checkout).
