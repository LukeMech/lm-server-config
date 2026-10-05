#!/bin/bash
# mongo-upgrade.sh <svc> <data dir> <target major>: ExecStartPre of a MongoDB
# container. mongod only opens data files of its own or the previous major
# version, so data left by an older image is stepped up one major at a time
# (start it with that version, set its featureCompatibilityVersion, stop it).
# The data's version is kept next to it, in <data dir>.version; data from
# before that file existed is 4.4 (the image sugar-mongo used until then).
set -euo pipefail
. /usr/libexec/lm-server/lib.sh

svc=$1 data=$2 target=$3
marker="${data}.version"
mkdir -p "${data}"

if [[ -f ${marker} ]]; then
    cur=$(<"${marker}")
elif [[ -z $(ls -A "${data}") ]]; then
    cur=${target} # fresh: created by the target version itself
else
    cur=4.4
fi

# newer <a> <b>: a is a later version than b.
newer() { [[ $1 != "$2" && $(printf '%s\n' "$1" "$2" | sort -V | tail -1) == "$1" ]]; }

for v in 5.0 6.0 7.0 8.0; do
    newer "${v}" "${cur}" || continue
    newer "${v}" "${target}" && break

    lms_log "${svc}: upgrading MongoDB data ${cur} -> ${v}"
    name="${svc}-upgrade"
    podman rm -f "${name}" &>/dev/null || true
    podman run -d --name "${name}" --network none \
        -v "${data}:/data/db:Z" "docker.io/library/mongo:${v}" >/dev/null
    shell=$(podman exec "${name}" sh -c 'command -v mongosh || command -v mongo')
    ok=""
    for _ in $(seq 1 60); do
        podman exec "${name}" "${shell}" --quiet --eval 'db.adminCommand({ping: 1}).ok' &>/dev/null && ok=1 && break
        sleep 2
    done
    if [[ -z ${ok} ]]; then
        podman logs --tail 30 "${name}" >&2 || true
        podman rm -f "${name}" >/dev/null
        lms_die "${svc}: MongoDB ${v} did not start on the ${cur} data (a CPU without AVX?)"
    fi
    # 7.0+ wants confirm: true; older versions reject unknown fields.
    confirm=""
    [[ ${v%%.*} -ge 7 ]] && confirm=", confirm: true"
    podman exec "${name}" "${shell}" --quiet --eval \
        "const r = db.adminCommand({setFeatureCompatibilityVersion: '${v}'${confirm}}); printjson(r); if (!r.ok) quit(1)" >&2 ||
        { podman rm -f "${name}" >/dev/null; lms_die "${svc}: setting featureCompatibilityVersion ${v} failed"; }
    podman stop -t 120 "${name}" >/dev/null
    podman rm "${name}" >/dev/null
    cur=${v}
    echo "${cur}" >"${marker}"
done

echo "${cur}" >"${marker}"
