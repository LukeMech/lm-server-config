#!/bin/bash
# Clone/pull APP_REPO, prepare it, serve it with gunicorn; exit (and get
# restarted by systemd) as soon as a new commit is pushed.
#
#   APP_REPO             owner/name on GitHub (required)
#   APP_BRANCH           default main
#   APP_MODULE           gunicorn app, e.g. server:app (required)
#   APP_PORT             listen port (required)
#   APP_GITHUB_TOKEN     token for private repos (+ APP_GITHUB_USER)
#   APP_BUILD_CMD        run after every pull (e.g. rendercv render ...)
#   APP_WORKERS          gunicorn workers, default 2
#   APP_UPDATE_INTERVAL  seconds between pulls, default 180
#
# Nothing is pip-installed per site: every package the sites need is in the
# image (see Containerfile), so a site's requirements.txt is not used.
set -euo pipefail

: "${APP_REPO:?APP_REPO is required}" "${APP_MODULE:?}" "${APP_PORT:?}"
APP_BRANCH=${APP_BRANCH:-main}
APP_WORKERS=${APP_WORKERS:-2}
APP_UPDATE_INTERVAL=${APP_UPDATE_INTERVAL:-180}
APP=/data/app

git_() {
    if [[ -n ${APP_GITHUB_TOKEN:-} ]]; then
        local auth
        auth=$(printf '%s:%s' "${APP_GITHUB_USER:-x-access-token}" "${APP_GITHUB_TOKEN}" | base64 -w0)
        GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 \
            GIT_CONFIG_KEY_0=http.https://github.com/.extraheader \
            GIT_CONFIG_VALUE_0="Authorization: Basic ${auth}" git "$@"
    else
        GIT_TERMINAL_PROMPT=0 git "$@"
    fi
}

url="https://github.com/${APP_REPO}.git"
if [[ -d ${APP}/.git ]]; then
    git_ -C "${APP}" fetch -q --depth 1 origin "${APP_BRANCH}"
    git -C "${APP}" reset -q --hard FETCH_HEAD
    git -C "${APP}" clean -qfd -e rendercv_output
else
    rm -rf "${APP}"
    git_ clone -q --depth 1 --branch "${APP_BRANCH}" "${url}" "${APP}"
fi
cd "${APP}"
rev=$(git rev-parse HEAD)
echo "webapp: ${APP_REPO}@${rev:0:12}"

# Per-site virtualenv of older image versions.
rm -rf /data/venv /data/.pip-state

# Flask-Babel reads compiled .mo files; sites may ship only the .po sources.
# Through the module: Fedora's python3-babel has no pybabel command.
if [[ -d translations ]]; then
    if python3 -m babel.messages.frontend compile -f -d translations >/dev/null; then
        echo "webapp: translations compiled ($(find translations -name '*.mo' | wc -l) catalogs)"
    else
        echo "webapp: compiling translations failed -- the site runs untranslated" >&2
    fi
fi
if [[ -n ${APP_BUILD_CMD:-} ]]; then
    bash -c "${APP_BUILD_CMD}"
fi

python3 -m gunicorn --bind "0.0.0.0:${APP_PORT}" --workers "${APP_WORKERS}" \
    --access-logfile - "${APP_MODULE}" &
pid=$!
trap 'kill -TERM "${pid}" 2>/dev/null; wait "${pid}"; exit 0' TERM INT

while sleep "${APP_UPDATE_INTERVAL}" & wait $!; do
    kill -0 "${pid}" 2>/dev/null || exit 1
    if git_ -C "${APP}" fetch -q --depth 1 origin "${APP_BRANCH}" &&
        [[ $(git -C "${APP}" rev-parse FETCH_HEAD) != "${rev}" ]]; then
        echo "webapp: new commit on ${APP_BRANCH} -- restarting"
        kill -TERM "${pid}"
        wait "${pid}" || true
        exit 0
    fi
done
