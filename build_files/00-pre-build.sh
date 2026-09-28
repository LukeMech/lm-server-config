#!/bin/bash
set -ouex pipefail

# Never install weak dependencies (Recommends/Supplements).
grep -q '^install_weak_deps' /etc/dnf/dnf.conf ||
    sed -i '/^\[main\]/a install_weak_deps=False' /etc/dnf/dnf.conf

# Everything lm-server itself relies on, listed explicitly -- even what
# fedora-bootc ships today -- so a base-image change can't silently drop it.
# (post-build.sh checks the resulting commands are really there.)
dnf5 -y install \
    `# containers: podman + quadlet, netavark networks, auto-update/pull` \
    aardvark-dns \
    conmon \
    containers-common \
    crun \
    netavark \
    podman \
    skopeo \
    `# system updates` \
    bootc \
    `# network, remote access, firewall` \
    firewalld \
    NetworkManager \
    openssh-server \
    `# lm-server scripts: git (secrets repo), jq/curl (provisioning), python3 (render.py), rsync (moving data between disks)` \
    coreutils \
    curl \
    git \
    jq \
    python3 \
    rsync \
    shadow-utils \
    util-linux \
    `# data disks (Cockpit > Storage): mdraid + XFS` \
    mdadm \
    xfsprogs

systemctl enable sshd.service NetworkManager.service podman.socket
