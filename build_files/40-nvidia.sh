#!/bin/bash
# NVIDIA driver for the X99 machine's GeForce GTX 1050 (Pascal). Its Xeon
# E5-2680 v4 has no iGPU, so the card is the only display.
#
# Everything comes prebuilt from the deps image (deps/build_files/10-nvidia.sh,
# bind-mounted at /deps-rpms): RPM Fusion's 580xx driver -- the last branch
# with Pascal -- its kmod built for this image's kernel (01-kernel.sh), and
# nvidia-container-toolkit-base. Their remaining dependencies come from
# AlmaLinux's repos; no third-party repo is enabled here.
#
# On the i5-4590 machine (no NVIDIA card) none of it ever loads.
set -ouex pipefail

kver=$(</deps-rpms/KVER)

dnf -y install /deps-rpms/nvidia/*.rpm

# The card for containers ([immich] gpu = "nvidia"): podman hands it over
# through CDI; nvidia-cdi-refresh writes /run/cdi/nvidia.yaml at every boot
# (lm-server's drop-in: only with an NVIDIA card in the machine).
systemctl enable nvidia-cdi-refresh.path nvidia-cdi-refresh.service

# The module for this kernel, from the kmod RPM, of the driver's version.
module=$(modinfo -k "${kver}" -F filename nvidia)
rpm -qf "${module}"
[[ $(modinfo -k "${kver}" -F version nvidia) == "$(</deps-rpms/NVIDIA)" ]]
[[ $(rpm -q --qf '%{VERSION}' xorg-x11-drv-nvidia-580xx) == "$(</deps-rpms/NVIDIA)" ]]
