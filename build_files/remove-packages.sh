#!/bin/bash
# Packages almalinux-bootc ships that lm-server has no use for. Removed first
# thing, before anything is installed -- by build.sh for the system image and
# by iso/Containerfile for the installer -- so a later install that really
# requires one just brings it back instead of dnf remove taking the installed
# packages with it.
#
# remove-packages.sh --check [package...] [--commands command...], once
# everything is installed (post-build.sh, iso/Containerfile): the one "is it
# all there" check -- warns about removed packages an install brought back,
# fails if the base packages below (KEEP), the given packages or the given
# commands are missing (listing all of them, not just the first).
#
# Hardware this leaves supported (the installer and the installed system
# alike): Intel machines like lm-server -- i5-4590 (Haswell), its i915 iGPU
# and an e1000e NIC, none of which loads firmware. NOT supported: AMD CPUs,
# AMD/NVIDIA GPUs, Intel iGPUs from 6th gen/Skylake on (GuC/HuC/DMC), Realtek
# NICs (r8169, USB r8152), Wi-Fi, Bluetooth, WWAN, onboard sound.
# linux-firmware (other wired NICs, storage controllers) and microcode_ctl
# (Intel CPU microcode) stay.
#
# Kept although unused, because something in the image requires them:
# os-prober (grub2-tools), clevis (almalinux-bootc's dracut config adds its
# module: the initramfs rebuild fails without it).
set -ouex pipefail

REMOVE=(
    # Firmware for hardware the server doesn't have (see above).
    amd-ucode-firmware
    amd-gpu-firmware
    intel-gpu-firmware
    nvidia-gpu-firmware
    realtek-firmware
    atheros-firmware
    brcmfmac-firmware
    iwlwifi-dvm-firmware
    iwlwifi-mvm-firmware
    iwlegacy-firmware
    libertas-firmware
    mt7xxx-firmware
    nxpwireless-firmware
    tiwilink-firmware
    qcom-wwan-firmware
    cirrus-audio-firmware
    intel-audio-firmware
    # No Bluetooth (the kernel modules are blocked in
    # /usr/lib/modprobe.d/lm-server-no-bluetooth.conf).
    bluez
    bluez-hid2hci
    bluez-libs
    bluez-obexd
    NetworkManager-bluetooth
    # No kdump: it can't find its dump target on bootc + btrfs (commit 536293a).
    kdump-utils
    kexec-tools
    makedumpfile
    memstrack
    # Nothing here mounts NFS (rpc.statd only logs errors at boot).
    nfs-utils
    rpcbind
    gssproxy
    quota
    # Joining AD / FreeIPA / LDAP domains: local accounts only.
    sssd-ad
    sssd-ipa
    sssd-krb5
    sssd-ldap
    adcli
    # Cloud VMs (Azure, cloud-init network, growing the root partition).
    WALinuxAgent-udev
    NetworkManager-cloud-setup
    cloud-utils-growpart
    # Desktop tools; the legacy iptables service (firewalld uses nftables).
    toolbox
    flatpak-session-helper
    iptables-nft-services
)

# Both images need these from the base image.
KEEP=(
    bootc dracut clevis-dracut grub2-efi-x64 grub2-tools shim-x64 linux-firmware
    microcode_ctl NetworkManager podman sudo flashrom
)

installed=()
for p in "${REMOVE[@]}"; do
    rpm -q "${p}" &>/dev/null && installed+=("${p}")
done

if [[ ${1:-} != --check ]]; then
    ((${#installed[@]})) && dnf -y remove "${installed[@]}"
    exit 0
fi

shift
packages=("${KEEP[@]}")
commands=()
while (($#)); do
    case "$1" in
    --commands) shift && commands+=("$@") && break ;;
    *) packages+=("$1") ;;
    esac
    shift
done

((${#installed[@]})) &&
    echo "warning: back in the image through dependencies:" "${installed[@]}" >&2
missing=()
for p in "${packages[@]}"; do
    rpm -q "${p}" &>/dev/null || missing+=("package ${p}")
done
for c in "${commands[@]}"; do
    command -v "${c}" >/dev/null || missing+=("command ${c}")
done
if ((${#missing[@]})); then
    printf 'error: missing from the image: %s\n' "${missing[@]}" >&2
    exit 1
fi
