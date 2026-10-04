#!/bin/bash
set -ouex pipefail

# What the server needs, now that everything is installed (and which of
# remove-packages.sh's removals came back): see remove-packages.sh --check.
# Packages: Cockpit and its pages, VMs. Commands: every one the lm-server
# scripts, units, Cockpit page and ostree (semodule, when finalizing an
# upgrade) call.
bash /ctx/remove-packages.sh --check \
    qemu-kvm-core libvirt-daemon-driver-qemu cockpit-machines virt-install \
    edk2-ovmf swtpm cockpit-ws cockpit-system cockpit-podman cockpit-storaged \
    cockpit-files firewalld sos xorg-x11-drv-nvidia-580xx \
    --commands \
    bootc cloudflared podman skopeo git jq curl python3 rsync mountpoint \
    systemd-escape flock base64 sha256sum od useradd usermod getent timedatectl \
    hostnamectl systemd-analyze firewall-cmd sshd cockpit-bridge mdadm mkfs.xfs \
    lvcreate smartctl mkfs.ext4 resize2fs losetup systemd-run ip blkid udevadm \
    pminfo tuned-adm semodule semanage setsebool restorecon nvidia-smi nvidia-ctk

kver=$(basename "$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)")

# Still only the deps image's kernel (00-pre-build.sh) -- nothing installed
# since brought another one along, which the NVIDIA kmod wouldn't match.
if [[ ${kver} != "$(</deps-rpms/KVER)" || $(rpm -qa kernel-core | wc -l) != 1 ]]; then
    echo "error: kernel is not just the deps image's $(</deps-rpms/KVER):" $(rpm -qa kernel-core) >&2
    exit 1
fi

# Kernel modules for both machines' hardware (remove-packages.sh): NICs,
# GPUs, CPU temperatures.
for module in e1000e igb r8169 i915 nvidia nvidia-drm coretemp; do
    modinfo -k "${kver}" -F filename "${module}" >/dev/null || {
        echo "error: kernel module ${module} missing from the image" >&2
        exit 1
    }
done

# Nothing Bluetooth may come back through another package's dependencies.
if bt=$(rpm -qa --qf '%{NAME} ' | tr ' ' '\n' | grep -iE '^bluez|bluetooth'); then
    echo "error: Bluetooth packages in the image:" ${bt} >&2
    exit 1
fi

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
DRACUT_NO_XATTR=1 dracut --no-hostonly --kver "${kver}" --reproducible --zstd --add ostree -f \
    "/usr/lib/modules/${kver}/initramfs.img"
chmod 0600 "/usr/lib/modules/${kver}/initramfs.img"

dnf -y clean all
rm -rf /var/lib/dnf
