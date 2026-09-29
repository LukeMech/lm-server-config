#!/bin/bash
# Drops the "/" line Anaconda writes to /etc/fstab. / is bootc's composefs,
# mounted from the kernel command line -- the line is never used (its remount
# is skipped, see systemd-remount-fs.service.d), and Cockpit > Storage shows
# the root partition as an "inconsistent mount point" because of it. Every
# other line (/boot, /boot/efi, data disks) stays. The original is kept once
# as /etc/fstab.lm-server-orig.
set -euo pipefail
. /usr/libexec/lm-server/lib.sh

fstab=/etc/fstab
is_root='$1 !~ /^[[:space:]]*#/ && $2 == "/"'
awk "${is_root} { found = 1 } END { exit !found }" "${fstab}" || exit 0

[[ -e ${fstab}.lm-server-orig ]] || cp -p "${fstab}" "${fstab}.lm-server-orig"
tmp=$(mktemp "${fstab}.XXXXXX")
awk "!(${is_root})" "${fstab}" >"${tmp}"
# Rewrite in place: keeps the file's owner, mode and SELinux label.
cat "${tmp}" >"${fstab}"
rm -f "${tmp}"
systemctl daemon-reload
lms_log "removed the unused / line from ${fstab} (original: ${fstab}.lm-server-orig)"
