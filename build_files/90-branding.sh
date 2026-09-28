#!/bin/bash
# Show "LM-Server <fedora version>" instead of "Fedora Linux" -- boot
# ("Welcome to ..."), the GRUB entry, /etc/issue and Cockpit all read
# PRETTY_NAME. ID/VERSION_ID stay fedora/44 so dnf, bootc and repo URLs keep
# working. post-build.sh rebuilds the initramfs so the initrd says it too.
set -ouex pipefail

f=/usr/lib/os-release
# shellcheck disable=SC1090
ver=$(. "${f}" && echo "${VERSION_ID}")
sed -i \
    -e "s/^NAME=.*/NAME=\"LM-Server\"/" \
    -e "s/^PRETTY_NAME=.*/PRETTY_NAME=\"LM-Server ${ver}\"/" \
    -e "s/^DEFAULT_HOSTNAME=.*/DEFAULT_HOSTNAME=\"lm-server\"/" \
    "${f}"
grep -q '^PRETTY_NAME="LM-Server ' "${f}"
