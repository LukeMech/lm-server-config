#!/bin/bash
# First thing in the build (build.sh runs it before everything else): the dnf setup, the kernel swap, the
# removal of unused base packages, then the packages lm-server relies on.
set -ouex pipefail

# Never install weak dependencies (Recommends/Supplements).
grep -q '^install_weak_deps' /etc/dnf/dnf.conf ||
    sed -i '/^\[main\]/a install_weak_deps=False' /etc/dnf/dnf.conf

### The kernel: the deps image's (deps/, bind-mounted at /deps-rpms) instead
# of the base image's own -- the NVIDIA kmod there (40-nvidia.sh) is built
# for exactly that one. Before anything else is removed or installed, so
# every later step already sees this kernel. Same swap as immutable-sbc's
# 00-pre-build.sh.
kver=$(</deps-rpms/KVER)

# No kernel-install plugins during the swap (rpm-ostree, dracut, bootloader:
# this is an image build, not a booted system). post-build.sh builds the
# initramfs once everything is installed.
mkdir -p /etc/kernel/install.d
skip=/etc/kernel/install.d/00-lm-server-skip.install
printf '%s\n' '#!/bin/sh' 'exit 77' >"${skip}"
chmod 0755 "${skip}"

mapfile -t old < <(rpm -qa --qf '%{NAME}\n' 'kernel*' | grep -xE 'kernel(-core|-modules(-[a-z]+)?)?' | sort -u)
rpm --erase --nodeps "${old[@]}"
rm -rf /usr/lib/modules
dnf -y install /deps-rpms/kernel/*.rpm

rm -f "${skip}"
depmod -a "${kver}"

# Exactly one kernel, the deps image's (post-build.sh checks again at the end).
[[ $(rpm -qa kernel-core) == "kernel-core-${kver}" ]] || {
    echo "error: kernel-core is not exactly ${kver}:" $(rpm -qa kernel-core) >&2
    exit 1
}
[[ -f /usr/lib/modules/${kver}/vmlinuz ]]

### Base packages lm-server has no use for, before anything is installed
# (see remove-packages.sh).
bash /ctx/remove-packages.sh

# Everything lm-server itself relies on, listed explicitly -- even what
# almalinux-bootc ships today -- so a base-image change can't silently drop it.
# (post-build.sh checks the resulting commands are really there.)
dnf -y install \
    `# containers: podman + quadlet, netavark networks, auto-update/pull` \
    aardvark-dns \
    conmon \
    containers-common \
    crun \
    netavark \
    podman \
    skopeo \
    `# system updates` \
    bootc \
    `# SELinux tools: ostree runs the new deployment's semodule to rebuild the policy when /etc/selinux has local changes (without it every upgrade fails to finalize); semanage/setsebool for Cockpit > SELinux` \
    policycoreutils \
    policycoreutils-python-utils \
    `# network, remote access, firewall` \
    firewalld \
    iproute \
    NetworkManager \
    openssh-server \
    `# lm-server scripts: git (secrets repo), jq/curl (provisioning), python3 (render.py), rsync (moving data between disks), e2fsprogs (fixed-size data disks, [<svc>] disk)` \
    coreutils \
    curl \
    e2fsprogs \
    git \
    jq \
    python3 \
    rsync \
    shadow-utils \
    util-linux \
    `# compressed swap in RAM (config: system_files/usr/lib/systemd/zram-generator.conf)` \
    zram-generator \
    `# data disks (Cockpit > Storage): mdraid + LVM + XFS, SMART health` \
    lvm2 \
    mdadm \
    smartmontools \
    udisks2-lvm2 \
    xfsprogs \
    `# when running as a VM (Proxmox shows the IP, clean shutdown); idle on bare metal` \
    qemu-guest-agent

# The first-boot prompt (lm-server-firstboot.service) is on /dev/tty1.
systemctl enable getty@tty1.service

systemctl enable sshd.service NetworkManager.service podman.socket

# Weekly read of the whole HDD mirror (mdadm's raid-check), repairs mismatches.
if [[ -f /usr/lib/systemd/system/raid-check.timer ]]; then
    systemctl enable raid-check.timer
else
    echo "warning: mdadm ships no raid-check.timer -- no periodic RAID check" >&2
fi

# Bound to the virtio-serial port the hypervisor adds (Proxmox: Options >
# QEMU Guest Agent): starts at boot in a VM, never runs on bare metal.
systemctl enable qemu-guest-agent.service
