#!/usr/bin/env bash

set -euo pipefail

packages=(
    python3
    python3-dev
    python3-pip
    python3-setuptools
    python3-venv
    python3-wheel
)

apt-get update
apt-get install -y --no-install-recommends "${packages[@]}"

ln -sf /usr/bin/python3 /usr/local/bin/python
ln -sf /usr/bin/pip3 /usr/local/bin/pip

cat > /etc/profile.d/python.sh <<EOF
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_ROOT_USER_ACTION=ignore
EOF
