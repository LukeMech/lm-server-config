#!/bin/bash
# ConvertX has no admin API: accounts are created through its /register form.
# Registration is opened just for this, then set back to the configured
# ACCOUNT_REGISTRATION. Existing accounts are left alone (password changes are
# done in the app).
set -euo pipefail
. /usr/libexec/lm-server/lib.sh

ENVDIR="${LMS_ENV}/convert"
USERS="${ENVDIR}/users.json"
# ConvertX answers under its WEBROOT (e.g. /converter), also locally.
URL=http://127.0.0.1:3001$(sed -n 's/^WEBROOT=//p' "${ENVDIR}/convert.env")
count=$(jq length "${USERS}")
((count > 0)) || exit 0

state="${LMS_STATE}/convert-users.sha256"
sum=$(sha256sum "${USERS}" | cut -d' ' -f1)
[[ $(cat "${state}" 2>/dev/null) == "${sum}" ]] && exit 0

cp "${ENVDIR}/convert.env" "${ENVDIR}/convert.env.orig"
restore() {
    mv -f "${ENVDIR}/convert.env.orig" "${ENVDIR}/convert.env"
    systemctl restart convert.service
}
trap restore EXIT
sed -i 's/^ACCOUNT_REGISTRATION=.*/ACCOUNT_REGISTRATION=true/' "${ENVDIR}/convert.env"
systemctl restart convert.service
lms_wait_http "${URL}/login" 600 || lms_die "convert: ConvertX did not come up"

for ((i = 0; i < count; i++)); do
    email=$(jq -r ".[${i}].email" "${USERS}")
    pass=$(jq -r ".[${i}].password" "${USERS}")
    curl -fsS -o /dev/null -X POST "${URL}/register" \
        --data-urlencode "email=${email}" --data-urlencode "password=${pass}" ||
        lms_log "convert: ${email} not registered (already exists?)"
done
echo "${sum}" >"${state}"
lms_log "convert: accounts registered"
