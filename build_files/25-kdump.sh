#!/bin/bash
# kdump: after a kernel panic, a crash kernel (kexec'd into the reserved
# memory, see usr/lib/bootc/kargs.d/10-crashkernel.toml) saves a vmcore to
# /var/crash and reboots -- the only trace of why the server went down.
# Cockpit > Kernel dump shows it and can test the setup. kdumpctl builds its
# initramfs at boot (under /var on ostree systems).
set -ouex pipefail

dnf -y install \
    kdump-utils \
    kexec-tools \
    makedumpfile

systemctl enable kdump.service
