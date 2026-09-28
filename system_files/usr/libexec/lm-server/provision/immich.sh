#!/bin/bash
# Immich: creates the admin on a fresh install (admin-sign-up), then every
# configured user that doesn't exist yet.
set -euo pipefail
. /usr/libexec/lm-server/lib.sh

ENVDIR="${LMS_ENV}/immich"
API=http://127.0.0.1:2283/api
ADMIN="${ENVDIR}/admin.json"

lms_wait_http "${API}/server/ping" 1800 || lms_die "immich: server did not come up"

if [[ $(curl -fsS "${API}/server/config" | jq -r '.isInitialized') != true ]]; then
    curl -fsS -o /dev/null -H 'Content-Type: application/json' -d @"${ADMIN}" "${API}/auth/admin-sign-up"
    lms_log "immich: admin $(jq -r .email "${ADMIN}") created"
fi

count=$(jq length "${ENVDIR}/users.json")
((count > 0)) || exit 0

token=$(jq '{email, password}' "${ADMIN}" |
    curl -fsS -H 'Content-Type: application/json' -d @- "${API}/auth/login" | jq -r '.accessToken') ||
    lms_die "immich: admin login failed (was the admin password changed in the app?)"
auth=(-H "Authorization: Bearer ${token}")
existing=$(curl -fsS "${auth[@]}" "${API}/admin/users" | jq -r '.[].email')

for ((i = 0; i < count; i++)); do
    user=$(jq -c ".[${i}] | {email, password, name: (.name // (.email | split(\"@\")[0]))}" "${ENVDIR}/users.json")
    email=$(jq -r .email <<<"${user}")
    grep -qxF "${email}" <<<"${existing}" && continue
    curl -fsS -o /dev/null "${auth[@]}" -H 'Content-Type: application/json' -d "${user}" "${API}/admin/users" &&
        lms_log "immich: user ${email} created"
done
