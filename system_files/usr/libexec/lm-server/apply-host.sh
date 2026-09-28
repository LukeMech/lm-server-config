#!/bin/bash
# Applies [host] + [updates] of lm-server.toml (rendered to env/host/):
# hostname, timezone, admin user, SSH keys, Cockpit origin, update schedules.
set -euo pipefail
. /usr/libexec/lm-server/lib.sh

HOST="${LMS_ENV}/host"
declare -A H=()
lms_read_env "${HOST}/host.env" H
set_if() { [[ -n ${1:-} && $1 != CHANGE_ME* ]]; }

if set_if "${H[TIMEZONE]:-}"; then
    timedatectl set-timezone "${H[TIMEZONE]}" || lms_log "invalid timezone ${H[TIMEZONE]}"
fi
if set_if "${H[HOSTNAME]:-}" && [[ $(hostnamectl hostname) != "${H[HOSTNAME]}" ]]; then
    hostnamectl set-hostname "${H[HOSTNAME]}"
fi

# Admin account (Cockpit + sudo).
admin=${H[ADMIN_USER]:-}
if set_if "${admin}"; then
    id "${admin}" &>/dev/null || useradd -m -G wheel "${admin}"
    usermod -aG wheel "${admin}"
    if set_if "${H[ADMIN_PASSWORD_HASH]:-}"; then
        usermod -p "${H[ADMIN_PASSWORD_HASH]}" "${admin}"
    fi
else
    admin=""
fi

if [[ -s ${HOST}/authorized_keys ]]; then
    for u in root ${admin}; do
        home=$(getent passwd "${u}" | cut -d: -f6)
        [[ -n ${home} ]] || continue
        install -d -m 0700 -o "${u}" -g "${u}" "${home}/.ssh"
        install -m 0600 -o "${u}" -g "${u}" "${HOST}/authorized_keys" "${home}/.ssh/authorized_keys"
    done
fi

# Cockpit behind cloudflared: the public origin(s) must be allowed. Setting
# Origins replaces Cockpit's default (the address in the browser), so the LAN
# ones -- hostname, localhost, every current IP -- are listed as well;
# otherwise https://<ip>:9090 loads but its websocket is refused.
{
    echo "# Written by lm-server from [host] cockpit_origins -- do not edit."
    echo "[WebService]"
    echo "ProtocolHeader = X-Forwarded-Proto"
    if [[ -n ${H[COCKPIT_ORIGINS]:-} ]]; then
        origins=""
        for o in ${H[COCKPIT_ORIGINS]}; do origins+="${o} ${o/https:/wss:} "; done
        for h in localhost "$(hostnamectl hostname)" $(hostname -I 2>/dev/null); do
            [[ ${h} == *:* ]] && h="[${h}]"
            origins+="https://${h}:9090 wss://${h}:9090 "
        done
        echo "Origins = ${origins% }"
    fi
} >/etc/cockpit/cockpit.conf.new
if cmp -s /etc/cockpit/cockpit.conf.new /etc/cockpit/cockpit.conf; then
    rm -f /etc/cockpit/cockpit.conf.new
else
    mv -f /etc/cockpit/cockpit.conf.new /etc/cockpit/cockpit.conf
    systemctl try-restart cockpit.service || true
fi

# Schedules are systemd timers (OnCalendar syntax: "hourly", "daily",
# "Sun 04:00", "*-*-* 03:00"; check one with `systemd-analyze calendar '<value>'`).
# "manual": system/container updates off; config sync only at boot + on demand.
CHANGED=()
# schedule <timer> <value> [boot-sync]
schedule() {
    local timer=$1 value=$2 dropin="/etc/systemd/system/$1.d/10-lm-server.conf" want
    if [[ ${value} == manual || ${value} == off ]]; then
        if [[ -z ${3:-} ]]; then
            systemctl disable --now "${timer}" 2>/dev/null || true
            return
        fi
        want=$(printf '[Timer]\nOnCalendar=\n') # keeps OnBootSec only
    else
        systemd-analyze calendar "${value}" >/dev/null 2>&1 || {
            lms_log "invalid schedule for ${timer}: ${value}"
            return
        }
        want=$(printf '[Timer]\nOnCalendar=\nOnCalendar=%s\n' "${value}")
    fi
    if [[ $(cat "${dropin}" 2>/dev/null) != "${want}" ]]; then
        mkdir -p "${dropin%/*}"
        printf '%s\n' "${want}" >"${dropin}"
        CHANGED+=("${timer}")
    elif ! systemctl is-active -q "${timer}"; then
        CHANGED+=("${timer}")
    fi
}
schedule lm-server-upgrade.timer "${H[SYSTEM_UPDATES]:-manual}"
schedule podman-auto-update.timer "${H[CONTAINER_UPDATES]:-daily}"
schedule lm-server-sync.timer "${H[CONFIG_UPDATES]:-hourly}" boot-sync
if ((${#CHANGED[@]})); then
    systemctl daemon-reload
    for t in "${CHANGED[@]}"; do
        systemctl enable "${t}" >/dev/null 2>&1 || true
        systemctl restart "${t}"
    done
fi
