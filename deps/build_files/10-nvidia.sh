#!/bin/bash
# NVIDIA driver for the X99 machine's GeForce GTX 1050 (Pascal, GP107),
# compute only: CUDA, NVENC/NVDEC and nvidia-smi -- no OpenGL/Vulkan/EGL, no
# Xorg (nothing on the server draws on the card; its text console is the
# kernel module's). NVIDIA's own CUDA repo splits it that way, ~450 MB
# installed instead of ~1 GB of RPM Fusion's desktop driver.
#
# Pascal needs the proprietary 580 branch: 590+ dropped Maxwell/Pascal/Volta
# and the open kernel modules never supported them. So: the newest 580.x in
# the repo, and its closed kernel modules (kmod-nvidia-latest-dkms) built by
# dkms for 00-kernel.sh's kernel. dkms would build at boot -- impossible with
# the server's read-only /usr -- so the modules go into an RPM of our own,
# kmod-nvidia, providing the nvidia-kmod the driver requires. Next to it the
# userspace of the very same version (a newer libnvidia-ml than the module =
# "Driver/library version mismatch") and nvidia-container-toolkit-base (CDI
# for podman): every RPM the system image needs from outside AlmaLinux --
# its build then installs them with AlmaLinux's repos alone.
set -ouex pipefail

kver=$(</rpms/KVER)
# The base image's EL major version (10 for almalinux-bootc:10).
el=$(rpm -E %rhel)

# EPEL: dkms. rpm-build: our kmod-nvidia RPM.
dnf -y install epel-release rpm-build
curl -fsSL -o /etc/yum.repos.d/cuda.repo \
    "https://developer.download.nvidia.com/compute/cuda/repos/rhel${el}/x86_64/cuda-rhel${el}.repo"
curl -fsSL -o /etc/yum.repos.d/nvidia-container-toolkit.repo \
    https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo
# -y on every dnf call, the first included: it imports the repos' keys
# (the toolkit repo signs its metadata too) -- without it dnf asks, nothing
# answers here, and the repo fails to load.

ver=$(dnf -y -q repoquery --qf '%{VERSION}\n' nvidia-driver-cuda | grep '^580\.' | sort -V | tail -1)
[[ -n ${ver} ]] || {
    echo "error: no 580.x nvidia-driver-cuda in NVIDIA's repo" >&2
    exit 1
}

# Userspace, with its dependencies -- before anything NVIDIA is installed
# here, or --resolve would skip what's already installed. Every NVIDIA
# package pinned to ${ver} (libnvidia-ml too: nvidia-smi only asks for its
# soname, which a newer branch's would satisfy). No weak dependencies (the
# system image installs none either). Kept: what isn't AlmaLinux's own, minus
# the module packages the driver's nvidia-kmod resolves to here (dkms
# sources, dkms) -- our kmod-nvidia provides it.
dl=$(mktemp -d)
dnf -y download --resolve --setopt=install_weak_deps=False --destdir "${dl}" \
    "nvidia-driver-cuda-${ver}" \
    "libnvidia-ml-${ver}" \
    nvidia-container-toolkit-base
for rpm in "${dl}"/*.rpm; do
    [[ $(rpm -qp --qf '%{VENDOR}' "${rpm}") == AlmaLinux* ]] && continue
    case $(rpm -qp --qf '%{NAME}' "${rpm}") in
    kmod-nvidia-* | dkms) continue ;;
    esac
    cp "${rpm}" /rpms/nvidia/
done

# The closed modules' source, without its scriptlets (they'd dkms-build for
# the runner's kernel), then dkms for ours (kernel-devel: 00-kernel.sh).
dnf -y install --setopt=tsflags=noscripts "kmod-nvidia-latest-dkms-${ver}"
dkms add -m nvidia -v "${ver}"
if ! dkms build -m nvidia -v "${ver}" -k "${kver}"; then
    cat "/var/lib/dkms/nvidia/${ver}/build/make.log" >&2 || true
    exit 1
fi
built="/var/lib/dkms/nvidia/${ver}/${kver}/$(uname -m)/module"

# Our kmod-nvidia RPM: the modules where the kernel looks for them.
root=$(mktemp -d)
moddir="${root}/usr/lib/modules/${kver}/extra/nvidia"
install -d "${moddir}"
install -m 0644 "${built}"/*.ko* "${moddir}/"
ls "${moddir}"/nvidia.ko* >/dev/null
spec=$(mktemp --suffix=.spec)
cat >"${spec}" <<EOF
%global debug_package %{nil}
%global __os_install_post %{nil}

Name: kmod-nvidia
Version: ${ver}
Release: 1.${kver//-/_}
Summary: NVIDIA ${ver} closed kernel modules for ${kver}
License: NVIDIA
Provides: nvidia-kmod = ${ver}
Requires: kernel-uname-r = ${kver}

%description
NVIDIA's closed kernel modules ${ver} (kmod-nvidia-latest-dkms), built by
dkms for ${kver} -- lm-server's deps image.

%files
/usr/lib/modules/${kver}/extra/nvidia

%post
depmod -a ${kver}

%postun
depmod -a ${kver}
EOF
top=$(mktemp -d)
rpmbuild -bb --define "_topdir ${top}" --buildroot "${root}" "${spec}"
kmod=$(find "${top}/RPMS" -name "kmod-nvidia-${ver}-*.rpm" -print -quit)
[[ -n ${kmod} ]] || {
    echo "error: rpmbuild built no kmod-nvidia-${ver}" >&2
    exit 1
}
cp "${kmod}" /rpms/nvidia/

# Module and userspace of one version.
[[ $(rpm -qp --qf '%{VERSION}' /rpms/nvidia/nvidia-driver-cuda-[0-9]*.rpm) == "${ver}" ]]
[[ $(rpm -qp --qf '%{VERSION}' /rpms/nvidia/libnvidia-ml-[0-9]*.rpm) == "${ver}" ]]
echo "${ver}" >/rpms/NVIDIA
ls -la /rpms/nvidia
