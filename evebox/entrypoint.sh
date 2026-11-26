#!/bin/sh
set -e

BCYAN=$(printf '\033[1;96m')
BGREEN=$(printf '\033[1;92m')
DIM=$(printf '\033[2m')
RESET=$(printf '\033[0m')

printf '\n\n%s' "$BCYAN"
cat <<'ART'
                           888                           
                           888                           
                           888                           
 .d88b.  888  888  .d88b.  88888b.   .d88b.  888  888    
d8P  Y8b 888  888 d8P  Y8b 888 "88b d88""88b `Y8bd8P'    
88888888 Y88  88P 88888888 888  888 888  888   X88K      
Y8b.      Y8bd8P  Y8b.     888 d88P Y88..88P .d8""8b.    
 "Y8888    Y88P    "Y8888  88888P"   "Y88P"  888  888    
ART
printf '%s  %sGroupe 2 · Console d'\''alertes EveBox (SQLite)%s\n\n\n' "$RESET" "$DIM" "$RESET"

DATA_DIR="/var/lib/evebox"

# Créer l'utilisateur défini dans .env au premier démarrage (aucun compte par défaut)
if [ ! -f "${DATA_DIR}/config.sqlite" ] && [ -n "${EVEBOX_USER}" ] && [ -n "${EVEBOX_PASSWORD}" ]; then
  printf '%s[evebox] Creation du compte analyste (%s)...%s\n' "$BGREEN" "$EVEBOX_USER" "$RESET"
  if ! evebox config users -D "${DATA_DIR}" add --username "${EVEBOX_USER}" --password "${EVEBOX_PASSWORD}" 2>/dev/null; then
    printf '%s\n%s\n' "${EVEBOX_PASSWORD}" "${EVEBOX_PASSWORD}" | evebox config users -D "${DATA_DIR}" add --username "${EVEBOX_USER}"
  fi
fi

exec evebox server --config /etc/evebox/evebox.yaml
