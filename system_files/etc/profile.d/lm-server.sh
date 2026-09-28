# shellcheck shell=sh
# Login hint until the secrets repo is configured.
if [ ! -e /var/lib/lm-server/secrets.env ] && [ -t 1 ]; then
    printf '\n  lm-server: configs not set up yet -- run: sudo lm-server setup\n\n'
fi
