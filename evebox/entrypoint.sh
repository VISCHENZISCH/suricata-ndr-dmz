#!/bin/sh
set -e

DATA_DIR="/var/lib/evebox"

# Créer l'utilisateur défini dans .env au premier démarrage (aucun compte par défaut)
if [ ! -f "${DATA_DIR}/config.sqlite" ] && [ -n "${EVEBOX_USER}" ] && [ -n "${EVEBOX_PASSWORD}" ]; then
  if ! evebox config users -D "${DATA_DIR}" add --username "${EVEBOX_USER}" --password "${EVEBOX_PASSWORD}" 2>/dev/null; then
    printf '%s\n%s\n' "${EVEBOX_PASSWORD}" "${EVEBOX_PASSWORD}" | evebox config users -D "${DATA_DIR}" add --username "${EVEBOX_USER}"
  fi
fi

exec evebox server --config /etc/evebox/evebox.yaml
