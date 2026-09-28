#!/bin/bash
# Web UI replacing the Proxmox GUI: the lm-server page (system + container
# updates, configs), containers (cockpit-podman), VMs (cockpit-machines),
# disks/RAID/mounts (cockpit-storaged), network.
set -ouex pipefail

dnf5 -y install \
    cockpit-files \
    cockpit-machines \
    cockpit-networkmanager \
    cockpit-podman \
    cockpit-selinux \
    cockpit-storaged \
    cockpit-system \
    cockpit-ws

# No per-package "Software updates" page: the system is updated as a whole
# image from the lm-server page. The overrides in /etc/cockpit/ also hide it
# if a dependency ever pulls one of these in.
dnf5 -y remove cockpit-packagekit cockpit-ostree || true

systemctl enable cockpit.socket
