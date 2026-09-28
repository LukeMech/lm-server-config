# shellcheck shell=sh
# Login hint until the secrets repo is configured. Only root can see
# /var/lib/lm-server (0700) -- and before setup root is the only account
# anyway (the admin comes from lm-server.toml), so other users skip the check.
if [ "$(id -u)" = 0 ] && [ ! -e /var/lib/lm-server/secrets.env ] && [ -t 1 ]; then
    printf '\n  lm-server: configs not set up yet -- run: lm-server setup\n\n'
fi
