#!/bin/bash
# The kernel lm-server ships: AlmaLinux's newest at the time of this build,
# resolved fresh every run (security updates flow in without a pin to bump;
# build-deps.yml publishes only when it -- or the driver -- changed). The
# system image replaces the base image's kernel with exactly these RPMs
# (build_files/01-kernel.sh), so the kmod built below always matches.
set -ouex pipefail

cd /rpms/kernel

# The same kernel packages the base image has (kernel, kernel-core,
# kernel-modules, kernel-modules-core, ...) -- the ones the swap replaces.
mapfile -t names < <(rpm -qa --qf '%{NAME}\n' 'kernel*' | grep -xE 'kernel(-core|-modules(-[a-z]+)?)?' | sort -u)
dnf -y download "${names[@]}"

kver=$(rpm -qp --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core-*.rpm)
for name in "${names[@]}"; do
    [[ -f ${name}-${kver}.rpm ]] || {
        echo "error: ${name}-${kver}.rpm not downloaded -- kernel packages resolved to different versions?" >&2
        ls -la >&2
        exit 1
    }
done

# This kernel in the builder too, with its kernel-devel: what the kmod is
# built against (next to the base image's own kernel).
dnf -y install ./*.rpm "kernel-devel-${kver}"
[[ -d /usr/src/kernels/${kver} ]]

echo "${kver}" >/rpms/KVER
