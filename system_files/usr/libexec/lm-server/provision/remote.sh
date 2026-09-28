#!/bin/bash
# Guacamole users straight into its PostgreSQL schema. Passwords are
# (re)set on every config change. If any user has admin = true, the default
# guacadmin/guacadmin account is disabled.
set -euo pipefail
. /usr/libexec/lm-server/lib.sh

USERS="${LMS_ENV}/remote/users.json"
count=$(jq length "${USERS}")
((count > 0)) || exit 0

psql() { podman exec -i remote-db psql -v ON_ERROR_STOP=1 -qAt -U guacamole -d guacamole_db "$@"; }
for _ in $(seq 1 180); do
    psql -c 'SELECT 1 FROM guacamole_user LIMIT 1' &>/dev/null && break
    sleep 5
done
psql -c 'SELECT 1 FROM guacamole_user LIMIT 1' >/dev/null || lms_die "remote: database not ready"

# SQL string literal.
sq() {
    local q="'"
    printf "'%s'" "${1//${q}/${q}${q}}"
}

sql="BEGIN;"
have_admin=0
for ((i = 0; i < count; i++)); do
    login=$(jq -r ".[${i}].login" "${USERS}")
    pass=$(jq -r ".[${i}].password" "${USERS}")
    salt=$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n' | tr 'a-f' 'A-F')
    # Guacamole: SHA-256 of (password + uppercase hex salt).
    hash=$(printf '%s%s' "${pass}" "${salt}" | sha256sum | cut -c1-64)
    l=$(sq "${login}")
    sql+="
INSERT INTO guacamole_entity (name, type) VALUES (${l}, 'USER') ON CONFLICT DO NOTHING;
INSERT INTO guacamole_user (entity_id, password_hash, password_salt, password_date, disabled)
  SELECT entity_id, decode('${hash}', 'hex'), decode('${salt}', 'hex'), now(), false
  FROM guacamole_entity WHERE name = ${l} AND type = 'USER'
  ON CONFLICT (entity_id) DO UPDATE SET password_hash = EXCLUDED.password_hash,
    password_salt = EXCLUDED.password_salt, password_date = now(), disabled = false;"
    if [[ $(jq -r ".[${i}].admin // false" "${USERS}") == true ]]; then
        have_admin=1
        for perm in ADMINISTER CREATE_CONNECTION CREATE_CONNECTION_GROUP CREATE_SHARING_PROFILE CREATE_USER CREATE_USER_GROUP; do
            sql+="
INSERT INTO guacamole_system_permission (entity_id, permission)
  SELECT entity_id, '${perm}' FROM guacamole_entity WHERE name = ${l} AND type = 'USER'
  ON CONFLICT DO NOTHING;"
        done
    fi
done
if ((have_admin)) && [[ $(jq '[.[] | select(.login == "guacadmin")] | length' "${USERS}") == 0 ]]; then
    sql+="
UPDATE guacamole_user SET disabled = true WHERE entity_id =
  (SELECT entity_id FROM guacamole_entity WHERE name = 'guacadmin' AND type = 'USER');"
fi
sql+="
COMMIT;"
psql <<<"${sql}"
lms_log "remote: ${count} guacamole user(s) applied"
