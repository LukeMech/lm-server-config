#!/bin/bash
# Syncthing GUI login + folders, FileBrowser users besides the admin.
set -euo pipefail
. /usr/libexec/lm-server/lib.sh

ENVDIR="${LMS_ENV}/disks"
ST="${ENVDIR}/syncthing.json"

# --- Syncthing: `syncthing cli` talks to the running instance.
st() { podman exec syncthing syncthing cli "$@"; }
for _ in $(seq 1 120); do
    st show system &>/dev/null && break
    sleep 5
done
st config gui user set "$(jq -r .user "${ST}")"
st config gui password set "$(jq -r .password "${ST}")"

# Folders: added if missing; an existing one (e.g. from a migrated config)
# gets its path corrected. Sharing them with devices stays in the Syncthing UI.
existing=$(st config folders list 2>/dev/null || true)
while IFS=$'\t' read -r id path; do
    if grep -qxF "${id}" <<<"${existing}"; then
        [[ $(st config folders "${id}" path get 2>/dev/null) == "${path}" ]] && continue
        st config folders "${id}" path set "${path}" &&
            lms_log "disks: syncthing folder ${id} moved to ${path}"
        continue
    fi
    st config folders add --id "${id}" --label "$(basename "${path}")" --path "${path}" &&
        lms_log "disks: syncthing folder ${id} -> ${path} added"
done < <(jq -r '.folders | to_entries[] | [.key, .value] | @tsv' "${ST}")
lms_log "disks: syncthing configured"

# --- FileBrowser: the admin comes from config.yaml; the CLI that adds users
# needs the database unlocked, so the container is stopped meanwhile.
count=$(jq length "${ENVDIR}/filebrowser-users.json")
((count > 0)) || exit 0

image=$(podman inspect filebrowser --format '{{.ImageName}}' 2>/dev/null ||
    echo docker.io/gtstef/filebrowser:stable)
systemctl stop filebrowser.service
trap 'systemctl start --no-block filebrowser.service' EXIT
for ((i = 0; i < count; i++)); do
    login=$(jq -r ".[${i}].login" "${ENVDIR}/filebrowser-users.json")
    pass=$(jq -r ".[${i}].password" "${ENVDIR}/filebrowser-users.json")
    podman run --rm --user 0:0 \
        -e FILEBROWSER_CONFIG=/home/filebrowser/config/config.yaml \
        -v "${ENVDIR}/filebrowser:/home/filebrowser/config:ro,Z" \
        -v "${LMS_VOLUMES}/disks/app/filebrowser:/home/filebrowser/data:Z" \
        --entrypoint ./filebrowser "${image}" \
        set -u "${login},${pass}" -c /home/filebrowser/config/config.yaml ||
        lms_log "disks: filebrowser user ${login} failed"
done
lms_log "disks: ${count} filebrowser user(s) set"
