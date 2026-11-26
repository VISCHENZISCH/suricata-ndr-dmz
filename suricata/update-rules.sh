#!/bin/sh
# Mise a jour des regles Emerging Threats Open et rechargement a chaud de la sonde.
# A executer depuis la racine du depot : ./suricata/update-rules.sh
set -eu

if [ -t 1 ]; then
    BOLD=$(printf '\033[1m')
    DIM=$(printf '\033[2m')
    BRED=$(printf '\033[1;91m')
    BGREEN=$(printf '\033[1;92m')
    BYELLOW=$(printf '\033[1;93m')
    BCYAN=$(printf '\033[1;96m')
    RESET=$(printf '\033[0m')
else
    BOLD=; DIM=; BRED=; BGREEN=; BYELLOW=; BCYAN=; RESET=
fi

printf '\n%s' "$BCYAN"
cat <<'ART'
                       888          888                                    888                   
                       888          888                                    888                   
                       888          888                                    888                   
888  888 88888b.   .d88888  8888b.  888888 .d88b.         888d888 888  888 888  .d88b.  .d8888b  
888  888 888 "88b d88" 888     "88b 888   d8P  Y8b        888P"   888  888 888 d8P  Y8b 88K      
888  888 888  888 888  888 .d888888 888   88888888 888888 888     888  888 888 88888888 "Y8888b. 
Y88b 888 888 d88P Y88b 888 888  888 Y88b. Y8b.            888     Y88b 888 888 Y8b.          X88 
 "Y88888 88888P"   "Y88888 "Y888888  "Y888 "Y8888         888      "Y88888 888  "Y8888   88888P' 
         888                                                                                     
         888                                                                                     
         888                                                                                     
ART
printf '%s  %sSuricata 7.0 · Emerging Threats Open & rechargement à chaud%s\n\n' "$RESET" "$DIM" "$RESET"

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if ! docker compose ps --status running --services | grep -qx suricata; then
    printf '%s[-] Le service suricata ne tourne pas. Lance : docker compose up -d%s\n' "$BRED" "$RESET" >&2
    exit 1
fi

printf '%s[*] Mise à jour des sources de règles...%s\n' "$BCYAN" "$RESET"
docker compose exec -T suricata suricata-update update-sources

printf '%s[*] Téléchargement des règles ET Open...%s\n' "$BCYAN" "$RESET"
docker compose exec -T suricata suricata-update --no-test

printf '%s[*] Rechargement de la configuration sans redémarrage...%s\n' "$BCYAN" "$RESET"
docker compose exec -T suricata suricatasc -c reload-rules || {
    printf '%s[!] Rechargement à chaud indisponible, redémarrage du conteneur%s\n' "$BYELLOW" "$RESET"
    docker compose restart suricata
}

printf '%s[+] Terminé. Règles actives :%s\n' "$BGREEN" "$RESET"
docker compose exec -T suricata suricata-update list-sources | head -5 || true
