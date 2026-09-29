#!/bin/bash
# Syncthing GUI login + folders, FileBrowser users besides the admin.
set -euo pipefail
. /usr/libexec/lm-server/lib.sh

ENVDIR="${LMS_ENV}/disks"
ST="${ENVDIR}/syncthing.json"

# --- Syncthing, over its REST API (the pod publishes it on 127.0.0.1:8384),
# with the API key from its config.xml -- stable across Syncthing versions,
# unlike `syncthing cli` inside the container (which has to find the config
# on its own, and broke with Syncthing 2).
URL=http://127.0.0.1:8384/rest
cfg=""
for _ in $(seq 1 120); do
    cfg=$(find "${LMS_VOLUMES}/disks/app/syncthing" -name config.xml -print -quit 2>/dev/null || true)
    [[ -n ${cfg} ]] && curl -fsS -o /dev/null "${URL}/noauth/health" 2>/dev/null && break
    sleep 5
done
[[ -n ${cfg} ]] || lms_die "disks: syncthing never wrote its config.xml"
key=$(sed -n 's:.*<apikey>\(.*\)</apikey>.*:\1:p' "${cfg}" | head -n1)
[[ -n ${key} ]] || lms_die "disks: no API key in ${cfg}"
api() { curl -fsS -H "X-API-Key: ${key}" -H 'Content-Type: application/json' "$@"; }

# GUI login. A plain password is stored hashed by Syncthing itself.
jq '{user, password}' "${ST}" | api -X PATCH -d @- "${URL}/config/gui" >/dev/null

# Folders: added if missing (Syncthing's defaults + id/label/path); an existing
# one (e.g. from a migrated config) gets its path corrected. Sharing them with
# devices stays in the Syncthing UI.
existing=$(api "${URL}/config/folders" | jq -r '.[] | [.id, .path] | @tsv')
defaults=$(api "${URL}/config/defaults/folder")
while IFS=$'\t' read -r id path; do
    have=$(awk -F'\t' -v id="${id}" '$1 == id { print $2 }' <<<"${existing}")
    if [[ -n ${have} ]]; then
        [[ ${have%/} == "${path%/}" ]] && continue
        jq -n --arg p "${path}" '{path: $p}' | api -X PATCH -d @- "${URL}/config/folders/${id}" >/dev/null &&
            lms_log "disks: syncthing folder ${id} moved to ${path}"
        continue
    fi
    jq --arg id "${id}" --arg label "$(basename "${path}")" --arg p "${path}" \
        '. + {id: $id, label: $label, path: $p}' <<<"${defaults}" |
        api -X POST -d @- "${URL}/config/folders" >/dev/null &&
        lms_log "disks: syncthing folder ${id} -> ${path} added"
done < <(jq -r '.folders | to_entries[] | [.key, .value] | @tsv' "${ST}")
lms_log "disks: syncthing configured (GUI login, $(jq '.folders | length' "${ST}") folders)"

# --- FileBrowser: the admin comes from config.yaml; the CLI that adds users
# needs the database unlocked, so the container is stopped meanwhile.
count=$(jq length "${ENVDIR}/filebrowser-users.json")
((count > 0)) || exit 0

image=$(podman inspect filebrowser --format '{{.ImageName}}' 2>/dev/null ||
    echo ghcr.io/gtsteffaniak/filebrowser:latest)
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
