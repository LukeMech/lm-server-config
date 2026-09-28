#!/bin/bash
# Shared helpers for lm-server (sourced, not executed).
# shellcheck disable=SC2034 # constants used by the scripts that source this

LMS_STATE=/var/lib/lm-server
LMS_SECRETS_ENV=${LMS_STATE}/secrets.env
LMS_REPO_DIR=${LMS_STATE}/secrets-repo
LMS_ENV=${LMS_STATE}/env
LMS_VOLUMES=${LMS_STATE}/volumes
LMS_LIBEXEC=/usr/libexec/lm-server
LMS_RENDER=${LMS_LIBEXEC}/render.py
LMS_DEFAULT_REPO=LukeMech/lm-server-config-secrets
LMS_CONFIG_FILE=lm-server.toml

lms_log() { echo "lm-server: $*" >&2; }
lms_die() {
    lms_log "error: $*"
    exit 1
}

# lms_read_env <file> <assoc-array-name>
# Literal KEY=VALUE parser -- never `source`s the file.
lms_read_env() {
    local file=$1 line
    local -n _lms_out=$2
    [[ -f ${file} ]] || return 0
    while IFS= read -r line || [[ -n ${line} ]]; do
        [[ ${line} =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
        _lms_out[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
    done <"${file}"
}

lms_env_line() {
    [[ $2 != *$'\n'* ]] || lms_die "value of $1 contains a newline"
    printf '%s=%s\n' "$1" "$2"
}

# Loads /var/lib/lm-server/secrets.env into LMS_S. Returns 1 if not set up yet.
lms_load_secrets() {
    declare -gA LMS_S=()
    [[ -f ${LMS_SECRETS_ENV} ]] || return 1
    lms_read_env "${LMS_SECRETS_ENV}" LMS_S
}

# git with the GitHub credentials from secrets.env (or LMS_GIT_TOKEN), passed
# through env-based git config so the token never lands in argv or .git/config.
lms_git() {
    local token=${LMS_GIT_TOKEN-${LMS_S[GITHUB_TOKEN]:-}}
    local user=${LMS_GIT_USER-${LMS_S[GITHUB_USER]:-}}
    if [[ -n ${token} ]]; then
        local auth
        auth=$(printf '%s:%s' "${user:-x-access-token}" "${token}" | base64 -w0)
        GIT_TERMINAL_PROMPT=0 \
            GIT_CONFIG_COUNT=2 \
            GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0='' \
            GIT_CONFIG_KEY_1=http.https://github.com/.extraheader \
            GIT_CONFIG_VALUE_1="Authorization: Basic ${auth}" \
            git "$@"
    else
        GIT_TERMINAL_PROMPT=0 git -c credential.helper= "$@"
    fi
}

# Service catalog (name<TAB>units<TAB>routes<TAB>description) -- render.py
# is the single source of truth.
lms_catalog() { "${LMS_RENDER}" services; }
lms_services() { lms_catalog | cut -f1; }
lms_service_exists() { lms_services | grep -qxF "$1"; }
lms_units() {
    lms_catalog | awk -F'\t' -v s="$1" '$1 == s { n = split($2, u, " "); for (i = 1; i <= n; i++) print u[i] ".service" }'
}
lms_enabled() { [[ -f ${LMS_ENV}/$1/enabled ]]; }

# Hash of a directory's contents (relative paths), ignoring the marker.
lms_dir_hash() {
    [[ -d $1 ]] || {
        echo none
        return
    }
    (cd "$1" && find . -type f ! -name enabled -print0 | sort -z | xargs -0r sha256sum | sha256sum | cut -d' ' -f1)
}

# lms_wait_http <url> [timeout-seconds] -- waits until the URL answers 2xx.
lms_wait_http() {
    local url=$1 timeout=${2:-900} start=${SECONDS}
    until curl -fsS -o /dev/null "${url}"; do
        ((SECONDS - start < timeout)) || return 1
        sleep 5
    done
}
