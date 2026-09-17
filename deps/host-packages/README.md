# host-packages

Builds the Ubuntu host .deb payload (mdns + wifi-client + wifi-ap) via appliance-code
`export-host-packages.sh`, archives it, and uploads to the files API:

`/api/v1/files/host-packages/ubuntu-24.04/<TARGET_ARCH>/<fingerprint>/host-packages.tar.zst`

Supports `TARGET_ARCH=amd64|arm64`. Cross-arch seed (arm64 on amd64 host) needs
a current `appliance-code` whose `export-host-packages.sh` fetches arm64 from
`ports.ubuntu.com/ubuntu-ports` (not archive.ubuntu.com). Requires an Ubuntu
packaging environment matching `OS_VERSION`, and `APPLIANCE_CODE_DIR` (or a
sibling `../appliance-code` checkout).
