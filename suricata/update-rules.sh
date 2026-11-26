#!/bin/sh
# Mise a jour des regles Emerging Threats Open et rechargement a chaud de la sonde.
# A executer depuis la racine du depot : ./suricata/update-rules.sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if ! docker compose ps --status running --services | grep -qx suricata; then
    echo "[-] Le service suricata ne tourne pas. Lance : docker compose up -d" >&2
    exit 1
fi

echo "[*] Mise a jour des sources de regles"
docker compose exec -T suricata suricata-update update-sources

echo "[*] Telechargement des regles ET Open"
docker compose exec -T suricata suricata-update --no-test

echo "[*] Rechargement de la configuration sans redemarrage"
docker compose exec -T suricata suricatasc -c reload-rules || {
    echo "[!] Rechargement a chaud indisponible, redemarrage du conteneur"
    docker compose restart suricata
}

echo "[+] Termine. Regles actives :"
docker compose exec -T suricata suricata-update list-sources | head -5 || true
