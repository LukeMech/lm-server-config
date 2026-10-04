#!/bin/bash
# 00-pre-build.sh first: the kernel swap, then removing the unused base
# packages -- before any install and before system_files (dnf remove would
# delete our files at a removed package's paths). Then every other numbered
# hook in build_files/ (10-, 15-, ...) in order, then post-build.sh last. Add
# a hook by adding a file -- no edit needed here.
set -ouex pipefail

bash /ctx/00-pre-build.sh

cp -avf /ctx/system_files/. /

for hook in /ctx/[0-9][0-9]-*.sh; do
    [[ ${hook} == */00-pre-build.sh ]] && continue
    bash "${hook}"
done

bash /ctx/post-build.sh
