#!/bin/bash
set -ouex pipefail

# Firmware / tools for hardware a headless server doesn't have (Wi-Fi, WWAN,
# sound, NVIDIA). Kept: CPU microcode, GPU firmware for iGPUs, realtek-firmware
# (r8169 Ethernet). nfs-utils: nothing here mounts NFS (its rpc.statd only logs
# errors at boot).
REMOVE=(
    atheros-firmware
    brcmfmac-firmware
    cirrus-audio-firmware
    intel-audio-firmware
    iwlwifi-dvm-firmware
    iwlwifi-mvm-firmware
    iwlegacy-firmware
    libertas-firmware
    mt7xxx-firmware
    nvidia-gpu-firmware
    nxpwireless-firmware
    qcom-wwan-firmware
    tiwilink-firmware
    nfs-utils
)
installed=()
for p in "${REMOVE[@]}"; do
    rpm -q "${p}" &>/dev/null && installed+=("${p}")
done
((${#installed[@]})) && dnf5 -y remove "${installed[@]}"

# Hard check: every command the lm-server scripts, units and Cockpit page call.
for cmd in bootc cloudflared podman skopeo git jq curl python3 rsync mountpoint systemd-escape flock base64 sha256sum od \
    useradd usermod getent timedatectl hostnamectl systemd-analyze \
    firewall-cmd sshd cockpit-bridge mdadm mkfs.xfs; do
    command -v "${cmd}" >/dev/null || {
        echo "error: required command '${cmd}' missing from the image" >&2
        exit 1
    }
done
python3 -c 'import tomllib'
test -x /usr/lib/systemd/system-generators/zram-generator

# Validate every quadlet (and its # lm-server: directives) now, not at first
# boot on the server.
/usr/libexec/lm-server/render.py services
/usr/libexec/podman/quadlet -dryrun >/dev/null

# Rebuild the initramfs: it carries its own copy of os-release (initrd-release),
# so without this the initrd still prints "Welcome to Fedora Linux".
kver=$(basename "$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)")
DRACUT_NO_XATTR=1 dracut --no-hostonly --kver "${kver}" --reproducible --zstd --add ostree -f \
    "/usr/lib/modules/${kver}/initramfs.img"
chmod 0600 "/usr/lib/modules/${kver}/initramfs.img"

dnf5 -y clean all
rm -rf /var/lib/dnf
