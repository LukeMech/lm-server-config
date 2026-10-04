#!/bin/bash
# The kernel from the deps image (deps/, bind-mounted at /deps-rpms) instead
# of the base image's own: the NVIDIA kmod there (40-nvidia.sh) is built for
# exactly that one. Same swap as immutable-sbc's 00-pre-build.sh.
set -ouex pipefail

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

# Exactly one kernel, the deps image's.
[[ $(rpm -qa kernel-core) == "kernel-core-${kver}" ]] || {
    echo "error: kernel-core is not exactly ${kver}:" $(rpm -qa kernel-core) >&2
    exit 1
}
[[ -f /usr/lib/modules/${kver}/vmlinuz ]]
