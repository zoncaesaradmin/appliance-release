#!/usr/bin/env bash

set -euo pipefail

NODE_VERSION="${NODE_VERSION:-22.19.0}"
TARGETARCH="${TARGETARCH:-}"

if [ -z "${TARGETARCH}" ]; then
    TARGETARCH="$(dpkg --print-architecture)"
fi

case "${TARGETARCH}" in
    amd64|x86_64)
        NODE_ARCH="x64"
        ;;
    arm64|aarch64)
        NODE_ARCH="arm64"
        ;;
    *)
        echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2
        exit 1
        ;;
esac

curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" -o /tmp/node.tar.xz
rm -rf /usr/local/node
mkdir -p /usr/local/node
tar -C /usr/local/node --strip-components=1 -xJf /tmp/node.tar.xz
rm -f /tmp/node.tar.xz

ln -sf /usr/local/node/bin/node /usr/local/bin/node
ln -sf /usr/local/node/bin/npm /usr/local/bin/npm
ln -sf /usr/local/node/bin/npx /usr/local/bin/npx

cat > /etc/profile.d/node.sh <<'EOF'
export PATH=/usr/local/node/bin:${PATH}
EOF
