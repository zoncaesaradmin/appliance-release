#!/usr/bin/env bash

set -euo pipefail

USERNAME="${USERNAME:-devcontainer}"
GO_VERSION="${GO_VERSION:-1.26.0}"
TARGETARCH="${TARGETARCH:-}"
USER_HOME="/home/${USERNAME}"

if [ -z "${TARGETARCH}" ]; then
    TARGETARCH="$(dpkg --print-architecture)"
fi

case "${TARGETARCH}" in
    amd64|x86_64)
        GO_ARCH="amd64"
        ;;
    arm64|aarch64)
        GO_ARCH="arm64"
        ;;
    *)
        echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2
        exit 1
        ;;
esac

curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" -o /tmp/go.tgz
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tgz
rm -f /tmp/go.tgz

ln -sf /usr/local/go/bin/go /usr/local/bin/go
ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt

mkdir -p "${USER_HOME}/go/bin" "${USER_HOME}/.cache/go-build"
cat > /etc/profile.d/go.sh <<EOF
export GOROOT=/usr/local/go
export GOPATH=${USER_HOME}/go
export PATH=\${GOROOT}/bin:\${GOPATH}/bin:\${PATH}
EOF

chown -R "${USERNAME}:${USERNAME}" "${USER_HOME}/go" "${USER_HOME}/.cache"
