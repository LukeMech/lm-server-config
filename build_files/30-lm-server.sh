#!/bin/bash
# lm-server tooling: first-boot setup, config sync, services, updates.
set -ouex pipefail

# Git on Windows may drop the exec bit -- set it explicitly.
chmod 0755 /usr/bin/lm-server /usr/libexec/lm-server/*.sh /usr/libexec/lm-server/render.py /usr/libexec/lm-server/containers.py /usr/libexec/lm-server/resources.py /usr/libexec/lm-server/provision/*.sh

# sudo ignores a drop-in that isn't 0440; a syntax error would lock sudo out.
chmod 0440 /etc/sudoers.d/lm-server-wheel
visudo -cf /etc/sudoers.d/lm-server-wheel

# UserNS=auto (web app quadlets) allocates per-container uid ranges from the
# "containers" entry.
grep -q '^containers:' /etc/subuid || echo 'containers:2147483647:2147483648' >>/etc/subuid
grep -q '^containers:' /etc/subgid || echo 'containers:2147483647:2147483648' >>/etc/subgid

systemctl enable \
    lm-server-firstboot.service \
    lm-server-fstab.service \
    lm-server-prune-adhoc.service \
    lm-server-services.service \
    lm-server-sync.timer \
    podman-auto-update.timer

# One updater for the OS, driven by AUTO_UPGRADE in the secrets repo
# (lm-server-upgrade.timer is enabled/disabled by apply-host.sh).
systemctl disable bootc-fetch-apply-updates.timer || true

# Firewall: LAN-facing ports only. Every web UI is published on 127.0.0.1
# and reached through cloudflared (host network) instead.
firewall-offline-cmd --add-service=ssh
firewall-offline-cmd --add-service=cockpit
firewall-offline-cmd --add-service=syncthing
systemctl enable firewalld.service
