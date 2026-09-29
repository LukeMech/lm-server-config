#!/bin/bash
# Web UI replacing the Proxmox GUI: the Management page (system image,
# container and config updates, config editor, setup), containers
# (cockpit-podman), VMs (cockpit-machines), disks/RAID/mounts
# (cockpit-storaged), network, metrics history (pcp + python3-pcp: the
# cockpit-pcp package is gone, Cockpit reads PCP through python3-pcp now).
set -ouex pipefail

dnf5 -y install \
    cockpit-files \
    cockpit-machines \
    cockpit-networkmanager \
    pcp \
    python3-pcp \
    cockpit-podman \
    cockpit-selinux \
    cockpit-storaged \
    cockpit-system \
    cockpit-ws

# No per-package "Software updates" page: the system is updated as a whole
# image from the Management page. The overrides in /etc/cockpit/ also hide it
# if a dependency ever pulls one of these in.
dnf5 -y remove cockpit-packagekit cockpit-ostree || true

systemctl enable cockpit.socket

# Overview > Metrics and history: PCP records CPU/RAM/disk/network (and per
# service) all the time, archives in /var/log/pcp (kept 14 days). pmproxy
# (export to the network) stays off.
systemctl enable pmcd.service pmlogger.service

# Overview > Performance profile: tuned, set to "powersave" (lower-clock
# governors, no turbo boost, SATA link power saving, writes flushed every
# 15 s). Changeable in Cockpit; bootc keeps a changed /etc/tuned across updates.
dnf5 -y install tuned
systemctl enable tuned.service
echo powersave >/etc/tuned/active_profile
echo manual >/etc/tuned/profile_mode
