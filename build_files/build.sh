#!/bin/bash
# Runs every numbered hook in build_files/ (00-, 01-, 10-, ...) in order,
# then post-build.sh last. Add a hook by adding a file -- no edit needed here.
# 00-pre-build.sh removes the unused base packages before 01-system-files.sh
# copies ours in (dnf remove would delete our files at a removed package's
# paths).
set -ouex pipefail

for hook in /ctx/[0-9][0-9]-*.sh; do
    bash "${hook}"
done

bash /ctx/post-build.sh
