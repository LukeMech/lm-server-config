#!/bin/bash
# Makes Anaconda's /etc/fstab match how bootc mounts the system disk, so
# Cockpit > Storage stops showing it as an "inconsistent mount point":
#
# - "/" line: / is bootc's composefs, mounted from the kernel command line --
#   the line is never used (its remount is skipped, see
#   systemd-remount-fs.service.d). Replaced by a line for /sysroot, where the
#   partition really is mounted (by the initrd). noauto: systemd never mounts
#   it from here; x-cockpit-never-auto: Cockpit doesn't offer to change that.
# - "/home" line of the same partition: on bootc /home is a symlink to
#   /var/home, which lives in the deployment's /var -- the line is unused and
#   dropped. If /var/home really is mounted from it, it's rewritten to
#   /var/home instead (the same mount, under its real path).
#
# Every other line (/boot, /boot/efi, data disks) stays. The original is kept
# once as /etc/fstab.lm-server-orig. Runs at every boot; no-op once done.
set -euo pipefail
. /usr/libexec/lm-server/lib.sh

fstab=/etc/fstab
[[ -f ${fstab} ]] || exit 0

# The partition behind /sysroot, e.g. UUID=... btrfs, FSROOT=/root (subvolume).
read -r uuid fstype fsroot < <(findmnt -n -f -o UUID,FSTYPE,FSROOT /sysroot) || exit 0
[[ -n ${uuid} ]] || exit 0
opts=noauto,x-cockpit-never-auto
[[ ${fstype} == btrfs && ${fsroot} != / ]] && opts="subvol=${fsroot#/},${opts}"
sysroot_line="UUID=${uuid} /sysroot ${fstype} ${opts} 0 0"
home_mounted=0
mountpoint -q /var/home && home_mounted=1

tmp=$(mktemp "${fstab}.XXXXXX")
trap 'rm -f "${tmp}"' EXIT
awk -v uuid="UUID=${uuid}" -v line="${sysroot_line}" -v home_mounted="${home_mounted}" '
    function emit_sysroot() { if (!done) { print line; done = 1 } }
    /^[[:space:]]*(#|$)/ { print; next }
    $2 == "/sysroot" { done = 1 }
    # First the /sysroot line: Cockpit uses the first line of a partition.
    { emit_sysroot() }
    $2 == "/" { next }
    $2 == "/home" && $1 == uuid {
        if (!home_mounted) next
        $2 = "/var/home"
    }
    { print }
    END { emit_sysroot() }
' "${fstab}" >"${tmp}"
cmp -s "${tmp}" "${fstab}" && exit 0

[[ -e ${fstab}.lm-server-orig ]] || cp -p "${fstab}" "${fstab}.lm-server-orig"
# Rewrite in place: keeps the file's owner, mode and SELinux label.
cat "${tmp}" >"${fstab}"
systemctl daemon-reload
lms_log "${fstab}: system disk lines match bootc now (original: ${fstab}.lm-server-orig)"
