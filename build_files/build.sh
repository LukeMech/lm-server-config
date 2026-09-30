#!/bin/bash
# Removes the unused base packages first (remove-packages.sh, before any
# install and before system_files: dnf remove would delete our files at a
# removed package's paths), then runs every numbered hook in build_files/
# (00-, 10-, ...) in order, then post-build.sh last. Add a hook by adding a
# file -- no edit needed here.
set -ouex pipefail

bash /ctx/remove-packages.sh

cp -avf /ctx/system_files/. /

for hook in /ctx/[0-9][0-9]-*.sh; do
    bash "${hook}"
done

bash /ctx/post-build.sh
