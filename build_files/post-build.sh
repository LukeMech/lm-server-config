#!/bin/bash
set -ouex pipefail

# Firmware / tools for hardware a headless server doesn't have (Wi-Fi, WWAN,
# Bluetooth, sound, GPUs, Realtek NICs), and features it doesn't use (below).
# nfs-utils: nothing here mounts NFS (its rpc.statd only logs errors at boot).
REMOVE=(
    # The server: Intel i5-4590 (Haswell) with its iGPU (i915) and an Intel
    # NIC (e1000e) -- none of them loads firmware. Intel CPU microcode is
    # microcode_ctl (stays). New hardware may need these back: AMD CPU/GPU,
    # Intel iGPU from Skylake on (GuC/HuC/DMC), Realtek NICs (r8169, USB r8152).
    amd-ucode-firmware
    amd-gpu-firmware
    intel-gpu-firmware
    realtek-firmware
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
    # No kdump (it can't find its dump target on bootc + btrfs, commit 536293a);
    # almalinux-bootc ships it.
    kdump-utils
    kexec-tools
    makedumpfile
    memstrack
    # Joining AD / FreeIPA / LDAP domains: local accounts only here.
    sssd-ad
    sssd-ipa
    sssd-krb5
    sssd-ldap
    adcli
    # Cloud VMs (Azure, cloud-init network, growing the root partition).
    WALinuxAgent-udev
    NetworkManager-cloud-setup
    cloud-utils-growpart
    # LUKS unlocked by TPM: no LUKS here.
    clevis
    clevis-dracut
    clevis-luks
    clevis-pin-tpm2
    clevis-systemd
    luksmeta
    jose
    # Desktop / NFS leftovers, the legacy iptables service (firewalld uses
    # nftables). os-prober stays: grub2-tools requires it.
    toolbox
    flatpak-session-helper
    rpcbind
    gssproxy
    quota
    iptables-nft-services
    # No Bluetooth on this server (the kernel modules are blocked in
    # /usr/lib/modprobe.d/lm-server-no-bluetooth.conf).
    bluez
    bluez-hid2hci
    bluez-libs
    bluez-obexd
    NetworkManager-bluetooth
)
installed=()
for p in "${REMOVE[@]}"; do
    rpm -q "${p}" &>/dev/null && installed+=("${p}")
done
((${#installed[@]})) && dnf -y remove "${installed[@]}"
# dnf remove also removes whatever requires a removed package: fail the build
# if that took anything the server needs.
KEEP=(
    qemu-kvm-core libvirt-daemon-driver-qemu cockpit-machines virt-install
    edk2-ovmf swtpm cockpit-ws cockpit-system cockpit-podman cockpit-storaged
    cockpit-files podman bootc NetworkManager firewalld sudo sos dracut
    grub2-efi-x64 shim-x64 linux-firmware microcode_ctl flashrom
)
for p in "${KEEP[@]}"; do
    rpm -q "${p}" &>/dev/null || {
        echo "error: '${p}' was removed along with REMOVE's packages" >&2
        exit 1
    }
done
# Nothing Bluetooth may come back through another package's dependencies.
if bt=$(rpm -qa --qf '%{NAME} ' | tr ' ' '\n' | grep -iE '^bluez|bluetooth'); then
    echo "error: Bluetooth packages in the image:" ${bt} >&2
    exit 1
fi

# Hard check: every command the lm-server scripts, units, Cockpit page and
# ostree (semodule, when finalizing an upgrade) call.
for cmd in bootc cloudflared podman skopeo git jq curl python3 rsync mountpoint systemd-escape flock base64 sha256sum od \
    useradd usermod getent timedatectl hostnamectl systemd-analyze \
    firewall-cmd sshd cockpit-bridge mdadm mkfs.xfs lvcreate smartctl \
    mkfs.ext4 resize2fs losetup systemd-run ip blkid udevadm pminfo tuned-adm \
    semodule semanage setsebool restorecon; do
    command -v "${cmd}" >/dev/null || {
        echo "error: required command '${cmd}' missing from the image" >&2
        exit 1
    }
done
# Every key policy.json points at must be in the image -- without it no
# ghcr.io/lukemech image can be pulled (bootc upgrade, the webapp containers).
for key in $(jq -r '.. | .keyPath? // empty' /etc/containers/policy.json); do
    grep -q 'BEGIN PUBLIC KEY' "${key}" || {
        echo "error: ${key} (from policy.json) missing from the image" >&2
        exit 1
    }
done
# zram-generator-defaults ships the same /usr/lib/systemd/zram-generator.conf
# as ours and would silently replace it.
if rpm -q zram-generator-defaults &>/dev/null; then
    echo "error: zram-generator-defaults is installed (it replaces our zram-generator.conf)" >&2
    exit 1
fi

# Validate every quadlet (and its # lm-server: directives) now, not at first
# boot on the server.
/usr/libexec/lm-server/render.py services
/usr/libexec/podman/quadlet -dryrun >/dev/null

# Rebuild the initramfs: it carries its own copy of os-release (initrd-release),
# so without this the initrd still prints "Welcome to AlmaLinux".
kver=$(basename "$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)")
DRACUT_NO_XATTR=1 dracut --no-hostonly --kver "${kver}" --reproducible --zstd --add ostree -f \
    "/usr/lib/modules/${kver}/initramfs.img"
chmod 0600 "/usr/lib/modules/${kver}/initramfs.img"

dnf -y clean all
rm -rf /var/lib/dnf
