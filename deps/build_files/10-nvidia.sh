#!/bin/bash
# NVIDIA driver for the X99 machine's GeForce GTX 1050 (Pascal, GP107).
#
# Pascal needs NVIDIA's proprietary 580 branch: 590+ dropped Maxwell/Pascal/
# Volta and the open kernel modules never supported them. RPM Fusion's
# nvidia-580xx packages (akmods, with akmodsbuild, from EPEL).
#
# akmod-nvidia-580xx is only the module source plus akmods, which builds a
# kmod RPM for one kernel -- normally at boot, which can't work with the
# server's read-only /usr. So it's built here, for 00-kernel.sh's kernel:
# kmod-nvidia-580xx-<kver>. Next to it, the driver's userspace of the very
# same version (a newer libnvidia-ml than the module = "Driver/library
# version mismatch") and nvidia-container-toolkit-base (CDI for podman, from
# NVIDIA's repo): every RPM the system image needs from outside AlmaLinux --
# its build then installs them with AlmaLinux's repos alone.
set -ouex pipefail

kver=$(</rpms/KVER)

dnf -y install epel-release
# The base image's EL major version (10 for almalinux-bootc:10).
el=$(rpm -E %rhel)
dnf -y install \
    "https://mirrors.rpmfusion.org/free/el/rpmfusion-free-release-${el}.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/el/rpmfusion-nonfree-release-${el}.noarch.rpm"
curl -fsSL -o /etc/yum.repos.d/nvidia-container-toolkit.repo \
    https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo

# Userspace, with its dependencies -- before anything NVIDIA is installed
# here, or --resolve would skip what's already installed. Only what isn't
# AlmaLinux's own is kept; the system image gets the rest from its repos.
# -cuda: nvidia-smi, CUDA/NVENC for containers.
dl=$(mktemp -d)
dnf -y download --resolve --destdir "${dl}" \
    xorg-x11-drv-nvidia-580xx-cuda \
    nvidia-container-toolkit-base
for rpm in "${dl}"/*.rpm; do
    [[ $(rpm -qp --qf '%{VENDOR}' "${rpm}") == AlmaLinux* ]] || cp "${rpm}" /rpms/nvidia/
done

# The kmod, against kernel-devel-<kver> (00-kernel.sh): akmodsbuild, called
# the way akmods itself calls it (as the akmods user), but into a directory
# of our own -- akmods builds into a temporary one, installs from there and
# only then copies the RPMs into its cache, under names not worth guessing.
dnf -y install akmod-nvidia-580xx
out=$(mktemp -d)
chown akmods "${out}"
if ! runuser -s /bin/bash -c "akmodsbuild --kernels ${kver} --outputdir ${out} \
    --logfile ${out}/akmodsbuild.log /usr/src/akmods/nvidia-580xx-kmod.latest" akmods; then
    cat "${out}/akmodsbuild.log" >&2 || true
    exit 1
fi
kmod=$(find "${out}" -name "kmod-nvidia-580xx-${kver}-*.rpm" ! -name '*debuginfo*' -print -quit)
[[ -n ${kmod} ]] || {
    echo "error: akmodsbuild built no kmod-nvidia-580xx for ${kver}:" >&2
    ls -la "${out}" >&2
    exit 1
}
cp "${kmod}" /rpms/nvidia/

# Module and userspace of one version (same repo, same minute -- checked).
driver=$(rpm -qp --qf '%{VERSION}' /rpms/nvidia/xorg-x11-drv-nvidia-580xx-[0-9]*.rpm)
module=$(rpm -qp --qf '%{VERSION}' "${kmod}")
[[ ${driver} == "${module}" ]] || {
    echo "error: kmod ${module} but driver userspace ${driver}" >&2
    exit 1
}
echo "${driver}" >/rpms/NVIDIA
ls -la /rpms/nvidia
