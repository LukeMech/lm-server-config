#!/bin/bash
# Web UI replacing the Proxmox GUI: the Updates page (system image,
# containers, config), the lm-server page (config editor, setup), containers
# (cockpit-podman), VMs (cockpit-machines), disks/RAID/mounts
# (cockpit-storaged), network.
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
# image from the Updates page. The overrides in /etc/cockpit/ also hide it
# if a dependency ever pulls one of these in.
dnf5 -y remove cockpit-packagekit cockpit-ostree || true

# "Updates" card on the Overview page: Cockpit has no extension point for
# Overview cards, so its page loads our script
# (/usr/share/cockpit/updates/overview-card.js, see there). Fails the build
# if a new cockpit-system changed the page, rather than silently losing it.
overview=/usr/share/cockpit/systemd/index.html
grep -q '<script[^>]*src="overview.js"' "${overview}"
sed -i 's|</head>|  <link rel="stylesheet" href="../updates/overview-card.css" />\n  <script src="../updates/overview-card.js" defer></script>\n</head>|' "${overview}"
grep -q 'updates/overview-card.js' "${overview}"

systemctl enable cockpit.socket
