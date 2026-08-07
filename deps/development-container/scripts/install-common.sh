#!/usr/bin/env bash

set -euo pipefail

USERNAME="${USERNAME:-devcontainer}"
USER_UID="${USER_UID:-1000}"
USER_GID="${USER_GID:-1000}"
USER_HOME="/home/${USERNAME}"

packages=(
    bash
    build-essential
    buildah
    ca-certificates
    curl
    fuse-overlayfs
    git
    gnupg2
    iproute2
    jq
    less
    openssh-client
    pkg-config
    podman
    procps
    rsync
    skopeo
    slirp4netns
    sudo
    uidmap
    unzip
    vim-tiny
    wget
    xz-utils
    zip
)

apt-get update
apt-get upgrade -y
apt-get install -y --no-install-recommends "${packages[@]}"

if ! getent group "${USERNAME}" >/dev/null 2>&1; then
    groupadd --gid "${USER_GID}" "${USERNAME}"
fi

if ! id -u "${USERNAME}" >/dev/null 2>&1; then
    useradd --uid "${USER_UID}" --gid "${USER_GID}" -m -s /bin/bash "${USERNAME}"
fi

usermod -aG sudo "${USERNAME}"
echo "${USERNAME} ALL=(root) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}"
chmod 0440 "/etc/sudoers.d/${USERNAME}"

mkdir -p /etc/containers
cat > /etc/containers/storage.conf <<EOF
[storage]
driver = "vfs"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"
EOF

cat > /etc/containers/containers.conf <<EOF
[engine]
cgroup_manager = "cgroupfs"
events_logger = "file"
EOF

echo "${USERNAME}:100000:65536" > /etc/subuid
echo "${USERNAME}:100000:65536" > /etc/subgid

mkdir -p "${USER_HOME}/.config/containers" "${USER_HOME}/.local/share/containers" "/run/user/${USER_UID}"
cat > "${USER_HOME}/.config/containers/storage.conf" <<EOF
[storage]
driver = "vfs"
runroot = "/run/user/${USER_UID}/containers"
graphroot = "${USER_HOME}/.local/share/containers/storage"
EOF

cat > /etc/profile.d/automation-container-tools.sh <<EOF
export XDG_RUNTIME_DIR=/run/user/${USER_UID}
export BUILDAH_ISOLATION=chroot
export STORAGE_DRIVER=vfs
EOF

chown -R "${USERNAME}:${USERNAME}" "${USER_HOME}" "/run/user/${USER_UID}"
