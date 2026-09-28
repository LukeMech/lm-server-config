#!/bin/bash
# Cloudflare Tunnel as part of the host (like it was on Proxmox), not a
# container: the package comes from Cloudflare's own RPM repo and is updated
# with the system image. The repo is only enabled for this install.
set -ouex pipefail

curl -fsSL https://pkg.cloudflare.com/cloudflared.repo -o /etc/yum.repos.d/cloudflared.repo
dnf5 -y install cloudflared
rm -f /etc/yum.repos.d/cloudflared.repo

# Unit: lm-server-cloudflared.service (own name, so the package's unit, if
# any, can't replace it) -- started by
# lm-server once [cloudflared] tunnel_token is configured, not at boot by itself.
