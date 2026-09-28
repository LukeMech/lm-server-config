#!/bin/bash
# Removes every container that isn't managed by a quadlet from this image
# (quadlets label theirs PODMAN_SYSTEMD_UNIT). Runs at boot, so ad-hoc
# containers made in Cockpit or with `podman run` live until the next reboot
# or system upgrade. [updates] adhoc_ephemeral = false keeps them.
set -euo pipefail
. /usr/libexec/lm-server/lib.sh

declare -A H=()
lms_read_env "${LMS_ENV}/host/host.env" H
if [[ ${1:-} != --force && ${H[ADHOC_EPHEMERAL]:-true} == false ]]; then
    exit 0
fi

# Pod infra containers are skipped; their pods go with `pod prune` below
# (quadlet pods are recreated on start anyway).
mapfile -t ids < <(podman ps -a --format '{{.ID}} {{.IsInfra}} {{index .Labels "PODMAN_SYSTEMD_UNIT"}}' |
    awk '$2 == "false" && $3 == "" { print $1 }')
if ((${#ids[@]})); then
    lms_log "removing ${#ids[@]} ad-hoc container(s)"
    podman rm -f "${ids[@]}"
fi
podman pod prune -f >/dev/null
podman volume prune -f >/dev/null
