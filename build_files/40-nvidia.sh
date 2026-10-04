#!/bin/bash
# NVIDIA driver for the X99 machine's GeForce GTX 1050 (Pascal, GP107). Its
# Xeon E5-2680 v4 has no iGPU, so the card is the only display.
#
# Pascal needs NVIDIA's proprietary 580 branch: 590+ dropped Maxwell/Pascal/
# Volta and the open kernel modules never supported them. RPM Fusion's
# nvidia-580xx packages (akmods itself comes from EPEL).
#
# akmod-nvidia-580xx is only the module source plus akmods, which builds a
# kmod RPM for one kernel -- normally at boot (akmods.service), which can't
# work with a read-only /usr. So it is built here, for this image's kernel
# (kmod-nvidia-580xx-<kver>), and akmods, the source and the compilers leave
# again. Every image build rebuilds it for its own kernel; the kernel never
# changes without a new image.
#
# On the i5-4590 machine (no NVIDIA card) none of it ever loads.
set -ouex pipefail

kver=$(basename "$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)")

dnf -y install epel-release
# The base image's EL major version (10 for almalinux-bootc:10).
el=$(rpm -E %rhel)
dnf -y install \
    "https://mirrors.rpmfusion.org/free/el/rpmfusion-free-release-${el}.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/el/rpmfusion-nonfree-release-${el}.noarch.rpm"

# kernel-devel of exactly this kernel, or akmods' plain kernel-devel
# dependency pulls in the newest one. -cuda: nvidia-smi (and CUDA/NVENC for
# containers).
dnf -y install \
    "kernel-devel-${kver}" \
    akmod-nvidia-580xx \
    xorg-x11-drv-nvidia-580xx-cuda

if ! akmods --force --kernels "${kver}"; then
    cat /var/cache/akmods/*/*.log >&2 || true
    exit 1
fi

# Build machinery and third-party repos out of the image (nothing runs dnf on
# the server). What the removals take along must not include the module or
# the driver: checked right after.
dnf -y remove akmods akmod-nvidia-580xx xorg-x11-drv-nvidia-580xx-kmodsrc "kernel-devel-${kver}"
dnf -y remove rpmfusion-nonfree-release rpmfusion-free-release epel-release

depmod -a "${kver}"
modinfo -k "${kver}" -F version nvidia
rpm -q "kmod-nvidia-580xx-${kver}" xorg-x11-drv-nvidia-580xx xorg-x11-drv-nvidia-580xx-cuda
