#!/bin/bash
# Runs every numbered hook in build_files/ (00-, 10-, ...) in order,
# then post-build.sh last. Add a hook by adding a file -- no edit needed here.
set -ouex pipefail

for hook in /ctx/[0-9][0-9]-*.sh; do
    bash "${hook}"
done

bash /ctx/post-build.sh
