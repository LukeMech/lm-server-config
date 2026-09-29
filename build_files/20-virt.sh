#!/bin/bash
# KVM/libvirt for full VMs that can't be containers (the old VM 104 win11),
# managed from Cockpit > Virtual machines.
#
# Modular libvirt (virtqemud & co., Fedora's default -- there is no monolithic
# libvirtd.socket) and qemu-kvm-core instead of libvirt-daemon-kvm/qemu-kvm,
# which pull in the GTK/SDL/audio front-ends a headless server never uses.
# VMs are shown over VNC/SPICE in Cockpit's console.
#
# Other architectures (emulated, no KVM -- slow, fine for tests, e.g. SBC
# images): ARM64 and RISC-V QEMU with their UEFI firmware. Cockpit's "Create
# VM" only makes host-architecture VMs, so those are created with
# virt-install (README: Virtual machines) and then run from Cockpit as usual.
set -ouex pipefail

dnf5 -y install \
    edk2-ovmf \
    libvirt-daemon-config-network \
    libvirt-daemon-driver-network \
    libvirt-daemon-driver-qemu \
    libvirt-daemon-driver-storage-core \
    qemu-kvm-core \
    swtpm \
    swtpm-tools \
    edk2-aarch64 \
    edk2-riscv64 \
    qemu-system-aarch64-core \
    qemu-system-riscv-core \
    virt-install

systemctl enable virtqemud.socket virtnetworkd.socket virtstoraged.socket
