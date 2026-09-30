#!/bin/bash
# KVM/libvirt for full VMs that can't be containers (the old VM 104 win11),
# managed from Cockpit > Virtual machines.
#
# Modular libvirt (virtqemud & co., EL's default -- there is no monolithic
# libvirtd.socket) and qemu-kvm-core instead of libvirt-daemon-kvm/qemu-kvm,
# which pull in the GTK/SDL/audio front-ends a headless server never uses.
# VMs are shown over VNC/SPICE in Cockpit's console. (10-cockpit.sh's Cockpit
# packages hard-require the full qemu-kvm anyway -- SPICE, OpenGL, audio --
# so it is already installed by the time this runs.)
#
# Host architecture (x86_64) only: EL ships no QEMU for other architectures
# (no qemu-system-aarch64/riscv64 in AlmaLinux, EPEL, Raven or GhettoForge).
set -ouex pipefail

dnf -y install \
    edk2-ovmf \
    libvirt-daemon-config-network \
    libvirt-daemon-driver-network \
    libvirt-daemon-driver-qemu \
    libvirt-daemon-driver-storage-core \
    qemu-kvm-core \
    swtpm \
    swtpm-tools \
    virt-install

systemctl enable virtqemud.socket virtnetworkd.socket virtstoraged.socket
