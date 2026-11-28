#!/bin/sh
set -eu

RELAY_FILE="/tmp/mailpit-relay.yml"

if [ -n "${MP_SMTP_RELAY_CONFIG:-}" ]; then
    if [ -n "${GMAIL_USER:-}" ] && [ -n "${GMAIL_APP_PASSWORD:-}" ]; then
        umask 077
        {
            printf 'host: smtp.gmail.com\n'
            printf 'port: 587\n'
            printf 'starttls: true\n'
            printf 'auth: plain\n'
            printf 'username: "%s"\n' "$(printf '%s' "$GMAIL_USER" | sed 's/\\/\\\\/g; s/"/\\"/g')"
            printf 'password: "%s"\n' "$(printf '%s' "$GMAIL_APP_PASSWORD" | sed 's/\\/\\\\/g; s/"/\\"/g')"
            printf 'override-from: "%s"\n' "$(printf '%s' "$GMAIL_USER" | sed 's/\\/\\\\/g; s/"/\\"/g')"
            printf 'return-path: "%s"\n' "$(printf '%s' "$GMAIL_USER" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        } > "$RELAY_FILE"
        export MP_SMTP_RELAY_CONFIG="$RELAY_FILE"
        echo "[mailpit] Relais SMTP Gmail active (${RELAY_FILE})."
    else
        echo "[mailpit] AVERTISSEMENT: MAILPIT_RELAY_CONFIG defini sans GMAIL_USER/GMAIL_APP_PASSWORD -> relais desactive." >&2
        unset MP_SMTP_RELAY_CONFIG MP_SMTP_RELAY_MATCHING
    fi
else
    unset MP_SMTP_RELAY_CONFIG MP_SMTP_RELAY_MATCHING
fi

exec /mailpit "$@"
