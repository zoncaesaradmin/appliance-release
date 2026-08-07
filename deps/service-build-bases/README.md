# service-build-bases

LAN build bases for control-plane / UI / hostagent image builds:

- `build-cache/golang:1.26`
- `build-cache/node:22-alpine`
- `build-cache/alpine-3.24.1-runtime:3.24.1` (apk packages preinstalled)
- `build-cache/controlplane-ui-web-deps:lockfile` (`npm ci` from vendored lockfile)

When the UI lockfile changes in appliance-code, copy `package.json` /
`package-lock.json` into `ui-npm/` and re-run `make release`.
