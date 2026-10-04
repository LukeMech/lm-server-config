#!/bin/bash
# Runs every numbered hook (00-, 10-, ...) in order. Nothing of this builder
# survives but /rpms (deps/Containerfile), so nothing is cleaned up.
set -ouex pipefail

install -d /rpms/kernel /rpms/nvidia

# dnf download (the base image has no dnf-plugins-core).
dnf -y install dnf-plugins-core

# Kernel packages installed here are only for building against: none of
# kernel-install's plugins (rpm-ostree, dracut, bootloader) need to run.
mkdir -p /etc/kernel/install.d
printf '%s\n' '#!/bin/sh' 'exit 77' >/etc/kernel/install.d/00-lm-server-skip.install
chmod 0755 /etc/kernel/install.d/00-lm-server-skip.install

for hook in /ctx/[0-9][0-9]-*.sh; do
    bash "${hook}"
done
