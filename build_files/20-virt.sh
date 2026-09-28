#!/bin/bash
# KVM/libvirt for full VMs that can't be containers (the old VM 104 win11).
# Managed from Cockpit > Virtual machines.
set -ouex pipefail

dnf5 -y install \
    libvirt-daemon-config-network \
    libvirt-daemon-kvm \
    qemu-kvm-core \
    swtpm \
    edk2-ovmf

systemctl enable libvirtd.socket
