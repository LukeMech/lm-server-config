#!/bin/bash
# Web UI replacing the Proxmox GUI: the lm-server page (container updates,
# configs), system image updates/rollback (cockpit-ostree, via rpm-ostree),
# containers (cockpit-podman), VMs (cockpit-machines), disks/RAID/mounts
# (cockpit-storaged), network.
set -ouex pipefail

dnf5 -y install \
    cockpit-files \
    cockpit-machines \
    cockpit-networkmanager \
    cockpit-ostree \
    cockpit-podman \
    cockpit-selinux \
    cockpit-storaged \
    cockpit-system \
    cockpit-ws \
    rpm-ostree

# No per-package updates (PackageKit): the system is updated as a whole image.
# Its page stays hidden by /etc/cockpit/packagekit.override.json even if a
# dependency pulls it in.
dnf5 -y remove cockpit-packagekit || true

systemctl enable cockpit.socket
