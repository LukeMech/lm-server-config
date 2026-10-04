#!/bin/bash
# NVIDIA driver for the X99 machine's GeForce GTX 1050 (Pascal). Its Xeon
# E5-2680 v4 has no iGPU, so the card is the only display.
#
# Everything comes prebuilt from the deps image (deps/build_files/10-nvidia.sh,
# bind-mounted at /deps-rpms): NVIDIA's 580 driver -- the last branch with
# Pascal -- compute only (CUDA, NVENC/NVDEC, nvidia-smi; no OpenGL/Vulkan/
# Xorg), its closed modules built for this image's kernel (00-pre-build.sh),
# and nvidia-container-toolkit-base. Their remaining dependencies come from
# AlmaLinux's repos; no third-party repo is enabled here.
#
# On the i5-4590 machine (no NVIDIA card) none of it ever loads.
set -ouex pipefail

kver=$(</deps-rpms/KVER)

# Without /usr/lib/firmware/nvidia (~100 MB, nvidia-kmod-common): GSP
# firmware, used only by Turing and newer -- never by the Pascal card.
# _netsharedpath makes rpm leave those files out.
echo '%_netsharedpath /usr/lib/firmware/nvidia' >/etc/rpm/macros.lm-server-nvidia
dnf -y install /deps-rpms/nvidia/*.rpm
rm -f /etc/rpm/macros.lm-server-nvidia
[[ ! -e /usr/lib/firmware/nvidia ]] || [[ -z $(ls -A /usr/lib/firmware/nvidia) ]]

# The card for containers ([immich] gpu = "nvidia"): podman hands it over
# through CDI; nvidia-cdi-refresh writes /run/cdi/nvidia.yaml at every boot
# (lm-server's drop-in: only with an NVIDIA card in the machine).
systemctl enable nvidia-cdi-refresh.path nvidia-cdi-refresh.service

# The module for this kernel, from our kmod-nvidia RPM, of the driver's
# version.
module=$(modinfo -k "${kver}" -F filename nvidia)
[[ $(rpm -qf --qf '%{NAME}' "$(readlink -f "${module}")") == kmod-nvidia ]]
[[ $(modinfo -k "${kver}" -F version nvidia) == "$(</deps-rpms/NVIDIA)" ]]
[[ $(rpm -q --qf '%{VERSION}' nvidia-driver-cuda) == "$(</deps-rpms/NVIDIA)" ]]

# Prebuilt only: nothing that would compile a module on the server.
if tooling=$(rpm -qa 'akmod*' 'dkms*' 'kmod-nvidia-*-dkms' 'kernel-devel*' | grep .); then
    echo "error: kmod build tooling in the image:" ${tooling} >&2
    exit 1
fi
# Compute only: none of the driver's graphics stack.
if graphics=$(rpm -qa 'nvidia-driver' 'nvidia-driver-libs' 'xorg-x11-drv-nvidia*' 'nvidia-settings*' | grep .); then
    echo "error: NVIDIA graphics packages in the image:" ${graphics} >&2
    exit 1
fi
