#!/bin/bash
# fastfetch: the system at a glance, in a shell and on Cockpit > Management.
# From EPEL, which is only enabled for this install: the repo (epel-release)
# is removed again, nothing else comes from it. A newer fastfetch comes with
# the next image build.
set -ouex pipefail

dnf -y install epel-release
dnf -y install fastfetch
dnf -y remove epel-release
