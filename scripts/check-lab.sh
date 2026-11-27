#!/bin/sh
#  Groupe 2 - Vérification complète de l'état du labo (DMZ + NDR + Supervision)
#  À exécuter depuis n'importe où (le script se place à la racine du dépôt) :
#      ./scripts/check-lab.sh [--no-banner] [--strict]

set -u

PASS=0
WARN=0
FAIL=0
STRICT=0
NO_BANNER="${NO_BANNER:-}"

DMZ_GW="${DMZ_GW:-172.20.0.1}"
WEB_URL="${WEB_URL:-http://127.0.0.1:8082}"
EVEBOX_URL="${EVEBOX_URL:-http://127.0.0.1:5636}"
GRAFANA_URL="${GRAFANA_URL:-http://127.0.0.1:3000}"
MAILPIT_URL="${MAILPIT_URL:-http://127.0.0.1:8025}"
EVE_MAX_AGE_MIN="${EVE_MAX_AGE_MIN:-60}"

EVE_JSON=/var/log/suricata/eve.json
RULES_DIR=/var/lib/suricata/rules

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    BOLD=$(printf '\033[1m')
    DIM=$(printf '\033[2m')
    BRED=$(printf '\033[1;91m')
    BGREEN=$(printf '\033[1;92m')
    BYELLOW=$(printf '\033[1;93m')
    BBLUE=$(printf '\033[1;94m')
    case "${TERM:-}" in
        *256color*|xterm*|tmux*|screen*|alacritty|kitty) ORANGE=$(printf '\033[1;38;5;208m') ;;
        *) ORANGE=$(printf '\033[1;97m') ;;
    esac
    RESET=$(printf '\033[0m')
else
    BOLD=; DIM=; BRED=; BGREEN=; BYELLOW=; BBLUE=; ORANGE=; RESET=
fi

usage() {
    cat <<'EOF'
Usage : check-lab.sh [options]

  --no-banner    n'affiche pas la bannière ASCII
  --strict       les WARN font aussi échouer le code de sortie
  -h, --help     affiche cette aide

Vérifie l'état complet du labo Suricata NDR :
  1. Configuration (.env, docker compose config)
  2. Conteneurs Docker (état Running / Healthy des 9 services)
  3. Endpoints HTTP & API (web, api, evebox, grafana, mailpit)
  4. Sonde Suricata (uptime, bridge promiscuous, eve.json, règles)
  5. Chaîne Promtail -> Loki -> Grafana (dashboards, alertes, logs)
  6. Conteneur attaquant (image g2/attacker:1.0)

Code de sortie : 0 si aucun FAIL (et aucun WARN avec --strict), 1 sinon, 2 si option invalide.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --no-banner) NO_BANNER=1 ;;
        --strict)    STRICT=1 ;;
        -h|--help)   usage; exit 0 ;;
        *)           printf 'Option inconnue : %s\n' "$arg" >&2; usage >&2; exit 2 ;;
    esac
done

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd) || exit 1
cd "$ROOT" || exit 1

#Helpers
have() { command -v "$1" >/dev/null 2>&1; }

# Timeout sur docker exec si disponible (évite un blocage si un conteneur est gelé).
T=""
have timeout && T="timeout 15"
dexec() { $T docker exec "$@"; }

# Convertit une sortie quelconque en entier (première ligne, chiffres uniquement, sinon 0).
to_int() {
    v=$(printf '%s\n' "${1:-}" | head -n 1 | tr -d '[:space:]')
    case "$v" in
        ''|*[!0-9]*) printf '0' ;;
        *)           printf '%s' "$v" ;;
    esac
}

# Lit une variable dans .env sans exécuter le fichier (pas de "source").
env_get() {
    [ -f .env ] || return 0
    sed -n "s/^$1=//p" .env | tail -n 1 | tr -d '\r' \
        | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

# http_code URL [user:pass] -> code HTTP, ou 000 si injoignable (jamais de doublon).
http_code() {
    if [ -n "${2:-}" ]; then
        code=$(curl -s -o /dev/null --connect-timeout 3 -m 6 -u "$2" -w '%{http_code}' "$1" 2>/dev/null) || true
    else
        code=$(curl -s -o /dev/null --connect-timeout 3 -m 6 -w '%{http_code}' "$1" 2>/dev/null) || true
    fi
    printf '%s' "${code:-000}"
}

# http_body URL [user:pass] -> corps de la réponse (vide si échec).
http_body() {
    if [ -n "${2:-}" ]; then
        body=$(curl -s --connect-timeout 3 -m 6 -u "$2" "$1" 2>/dev/null) || true
    else
        body=$(curl -s --connect-timeout 3 -m 6 "$1" 2>/dev/null) || true
    fi
    printf '%s' "${body:-}"
}

section() {
    printf '\n%s==> %s%s\n' "$BBLUE" "$1" "$RESET"
}

ok() {
    PASS=$((PASS + 1))
    printf '  %s[OK]%s   %s\n' "$BGREEN" "$RESET" "$1"
}

warn() {
    WARN=$((WARN + 1))
    printf '  %s[WARN]%s %s\n' "$BYELLOW" "$RESET" "$1"
}

fail() {
    FAIL=$((FAIL + 1))
    printf '  %s[FAIL]%s %s\n' "$BRED" "$RESET" "$1"
}

bilan() {
    RULE="**********************************************************************"
    if [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then
        c_bilan="$BGREEN"
        msg_bilan="[OK] Tout le labo est opérationnel (${PASS} OK, 0 WARN, 0 FAIL)."
    elif [ "$FAIL" -eq 0 ]; then
        c_bilan="$BYELLOW"
        msg_bilan="[WARN] Labo opérationnel avec avertissements (${PASS} OK, ${WARN} WARN, 0 FAIL)."
    else
        c_bilan="$BRED"
        msg_bilan="[FAIL] Anomalies détectées (${PASS} OK, ${WARN} WARN, ${FAIL} FAIL)."
    fi
    printf '\n%s%s%s\n' "$c_bilan" "$RULE" "$RESET"
    printf '  %s%s%s\n' "$c_bilan" "$msg_bilan" "$RESET"
    printf '%s%s%s\n\n' "$c_bilan" "$RULE" "$RESET"
}

exit_code() {
    [ "$FAIL" -eq 0 ] || return 1
    [ "$STRICT" -eq 0 ] || [ "$WARN" -eq 0 ] || return 1
    return 0
}

# Bannière 
if [ -z "$NO_BANNER" ]; then
    printf '\n\n%s' "$ORANGE"
    cat <<'ART'
         888                        888               888          888      
         888                        888               888          888      
         888                        888               888          888      
 .d8888b 88888b.   .d88b.   .d8888b 888  888          888  8888b.  88888b.  
d88P"    888 "88b d8P  Y8b d88P"    888 .88P          888     "88b 888 "88b 
888      888  888 88888888 888      888888K  888888   888 .d888888 888  888 
Y88b.    888  888 Y8b.     Y88b.    888 "88b          888 888  888 888 d88P 
 "Y8888P 888  888  "Y8888   "Y8888P 888  888          888 "Y888888 88888P"  
ART
    printf '%s  %sGroupe 2 · Contrôle de santé du labo Suricata NDR DMZ%s\n\n\n' "$RESET" "$DIM" "$RESET"
fi

# 1. Configuration locale 
section "1. Configuration & Compose"

if ! have docker; then
    fail "Commande docker introuvable sur l'hôte."
    bilan
    exit 1
fi

if [ -f .env ]; then
    ok "Fichier .env présent."
    for var in POSTGRES_PASSWORD EVEBOX_USER EVEBOX_PASSWORD GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD; do
        val=$(env_get "$var")
        if [ -z "$val" ]; then
            fail "Variable $var vide ou absente dans .env."
        else
            ok "Variable $var définie."
        fi
    done
else
    fail "Fichier .env absent (copier .env.example vers .env)."
fi

if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
elif have docker-compose; then
    DC="docker-compose"
else
    DC=""
fi

if [ -z "$DC" ]; then
    fail "Docker Compose introuvable (ni 'docker compose' ni 'docker-compose')."
elif cfg_out=$($DC config -q 2>&1); then
    ok "Configuration Docker Compose valide."
else
    fail "Configuration Docker Compose invalide : $(printf '%s' "$cfg_out" | head -n 1)"
fi

# 2. État des conteneurs 
section "2. État des conteneurs Docker"

if ! docker info >/dev/null 2>&1; then
    fail "Daemon Docker inaccessible."
    bilan
    exit 1
fi

check_container() {
    cname="$1"
    expect_health="$2"
    state=$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null) || state="absent"
    if [ "$state" != "running" ]; then
        fail "$cname : état=$state"
        return
    fi
    if [ "$expect_health" = "1" ]; then
        health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cname" 2>/dev/null) || health="none"
        case "$health" in
            healthy)  ok "$cname : running (healthy)" ;;
            starting) warn "$cname : running (health: starting)" ;;
            none)     warn "$cname : running (aucun healthcheck défini)" ;;
            *)        fail "$cname : running (health: $health)" ;;
        esac
    else
        ok "$cname : running"
    fi
}

check_container g2-web      1
check_container g2-db       1
check_container g2-api      1
check_container g2-evebox   1
check_container g2-suricata 1
check_container g2-mailpit  1
check_container g2-loki     0
check_container g2-promtail 0
check_container g2-grafana  0

# 3. Endpoints HTTP & APIs 
section "3. Endpoints HTTP & API (127.0.0.1)"

if have curl; then
    web_code=$(http_code "$WEB_URL/")
    if [ "$web_code" = "200" ]; then
        ok "Portail web ($WEB_URL) -> HTTP 200."
    else
        fail "Portail web ($WEB_URL) -> HTTP $web_code."
    fi

    api_body=$(http_body "$WEB_URL/api/health")
    if printf '%s' "$api_body" | grep -Eq '"db" *: *"up"'; then
        ok "API FastAPI + PostgreSQL (/api/health) -> $api_body"
    else
        fail "API FastAPI (/api/health) -> réponse inattendue : ${api_body:-vide}"
    fi

    eve_ping=$(http_code "$EVEBOX_URL/ping")
    eve_api=$(http_code "$EVEBOX_URL/api/alerts")
    if [ "$eve_ping" = "200" ] && [ "$eve_api" = "401" ]; then
        ok "EveBox ($EVEBOX_URL) -> /ping 200 et /api/alerts protégé (401)."
    elif [ "$eve_ping" = "200" ]; then
        warn "EveBox /ping 200, mais /api/alerts renvoie HTTP $eve_api (attendu : 401)."
    else
        fail "EveBox injoignable (/ping -> HTTP $eve_ping)."
    fi

    graf_health=$(http_body "$GRAFANA_URL/api/health")
    if printf '%s' "$graf_health" | grep -Eq '"database" *: *"ok"'; then
        ok "Grafana ($GRAFANA_URL/api/health) -> base de données OK."
    else
        fail "Grafana /api/health -> ${graf_health:-injoignable}"
    fi

    mp_body=$(http_body "$MAILPIT_URL/api/v1/messages")
    if printf '%s' "$mp_body" | grep -Eq '"total" *: *[0-9]+'; then
        mp_total=$(printf '%s' "$mp_body" | grep -Eo '"total" *: *[0-9]+' | head -n 1 | grep -Eo '[0-9]+$')
        ok "Mailpit ($MAILPIT_URL) -> API OK (${mp_total:-0} message(s) en boîte)."
    else
        fail "API Mailpit injoignable."
    fi
else
    warn "curl absent sur l'hôte : sections 3 et 5 ignorées."
fi

# 4. Sonde Suricata & capture bridge 
section "4. Sonde Suricata (capture, règles, eve.json)"

if [ "$(docker inspect -f '{{.State.Running}}' g2-suricata 2>/dev/null)" = "true" ]; then
    uptime_out=$(dexec g2-suricata suricatasc -c uptime 2>/dev/null) || true
    if printf '%s' "$uptime_out" | grep -Eq '"return" *: *"OK"'; then
        ok "Socket suricatasc actif."
    else
        fail "suricatasc -c uptime en échec."
    fi

    # Interface portant l'IP de la passerelle DMZ (analyse faite côté hôte, sans awk dans le conteneur).
    addrs=$(dexec g2-suricata ip -o -4 addr show 2>/dev/null) || true
    iface=$(printf '%s\n' "$addrs" | awk -v gw="$DMZ_GW" 'index($4, gw "/") == 1 { print $2; exit }')
    if [ -n "$iface" ]; then
        if dexec g2-suricata ip link show dev "$iface" 2>/dev/null | grep -q 'PROMISC'; then
            ok "Bridge DMZ $iface en mode PROMISC."
        else
            fail "Bridge DMZ $iface détecté, mais mode PROMISC inactif."
        fi
    else
        fail "Bridge DMZ ($DMZ_GW) introuvable depuis g2-suricata."
    fi

    if dexec g2-suricata test -f "$EVE_JSON" 2>/dev/null; then
        eve_lines=$(to_int "$(dexec g2-suricata sh -c "wc -l < $EVE_JSON" 2>/dev/null)")
        alert_lines=$(to_int "$(dexec g2-suricata grep -Ec '"event_type" *: *"alert"' "$EVE_JSON" 2>/dev/null)")
        if [ "$eve_lines" -gt 0 ]; then
            ok "eve.json alimenté : $eve_lines événements ($alert_lines alertes)."
            fresh=$(dexec g2-suricata find "$EVE_JSON" -mmin "-$EVE_MAX_AGE_MIN" 2>/dev/null) || true
            if [ -n "$fresh" ]; then
                ok "eve.json modifié depuis moins de $EVE_MAX_AGE_MIN min."
            else
                warn "eve.json inchangé depuis plus de $EVE_MAX_AGE_MIN min (pas de trafic sur le bridge ?)."
            fi
        else
            warn "eve.json présent mais vide pour l'instant."
        fi
    else
        warn "eve.json absent pour l'instant ($EVE_JSON)."
    fi

    et_size=$(to_int "$(dexec g2-suricata sh -c "wc -l < $RULES_DIR/suricata.rules" 2>/dev/null)")
    local_count=$(to_int "$(dexec g2-suricata grep -c '^alert ' "$RULES_DIR/local.rules" 2>/dev/null)")
    if [ "$et_size" -gt 100 ]; then
        ok "Règles ET Open chargées ($et_size lignes)."
    else
        warn "suricata.rules quasi vide ($et_size lignes) -> lancer ./suricata/update-rules.sh."
    fi
    if [ "$local_count" -ge 3 ]; then
        ok "Signatures custom local.rules actives ($local_count règles)."
    else
        fail "local.rules insuffisant ($local_count règles)."
    fi
else
    fail "g2-suricata arrêté : vérifications de la sonde ignorées."
fi

# 5. Chaîne Promtail -> Loki -> Grafana 
section "5. Supervision Promtail -> Loki -> Grafana"

GRAF_USER=$(env_get GRAFANA_ADMIN_USER)
GRAF_PASS=$(env_get GRAFANA_ADMIN_PASSWORD)

if ! have curl; then
    warn "Section 5 ignorée : curl absent."
elif [ -z "$GRAF_USER" ] || [ -z "$GRAF_PASS" ]; then
    warn "Section 5 ignorée : identifiants Grafana absents de .env."
else
    auth="${GRAF_USER}:${GRAF_PASS}"

    for uid in suri-direction suri-exploitation; do
        code=$(http_code "$GRAFANA_URL/api/dashboards/uid/${uid}" "$auth")
        if [ "$code" = "200" ]; then
            ok "Dashboard provisionné : $uid."
        else
            fail "Dashboard $uid introuvable (HTTP $code)."
        fi
    done

    # Une règle = une clé "ruleGroup" (le champ "uid" apparaît aussi dans les datasources).
    rules_json=$(http_body "$GRAFANA_URL/api/v1/provisioning/alert-rules" "$auth")
    rule_count=$(printf '%s' "$rules_json" | grep -o '"ruleGroup"' | wc -l | tr -d '[:space:]')
    rule_count=$(to_int "$rule_count")
    if [ "$rule_count" -ge 4 ]; then
        ok "Règles d'alerte Grafana chargées ($rule_count règles)."
    else
        warn "Nombre d'alertes Grafana faible ($rule_count, attendu >= 4)."
    fi

    loki_resp=$(curl -s --connect-timeout 3 -m 8 -u "$auth" -H "Content-Type: application/json" \
        -d '{"queries":[{"refId":"A","datasource":{"type":"loki","uid":"loki"},"expr":"sum(count_over_time({job=\"suricata\"}[1h]))","queryType":"instant"}],"from":"now-1h","to":"now"}' \
        "$GRAFANA_URL/api/ds/query" 2>/dev/null) || true
    if printf '%s' "$loki_resp" | grep -Eq '"status" *: *200'; then
        loki_count=$(printf '%s' "$loki_resp" \
            | grep -Eo '"values" *: *\[\[[0-9]+\] *, *\[[0-9.eE+]+\]\]' | head -n 1 \
            | sed -E 's/.*, *\[([0-9.eE+]+)\]\]$/\1/')
        if [ -n "$loki_count" ]; then
            ok "Flux Promtail -> Loki -> Grafana actif ($loki_count événements sur 1 h)."
        else
            warn "Loki répond (HTTP 200), mais aucun événement {job=\"suricata\"} sur 1 h."
        fi
    else
        fail "Requête Loki via Grafana en échec."
    fi
fi

# 6. Conteneur attaquant 
section "6. Poste attaquant (profil attack)"

if docker image inspect g2/attacker:1.0 >/dev/null 2>&1; then
    ok "Image g2/attacker:1.0 prête (lancer : docker compose run --rm attacker)."
else
    warn "Image g2/attacker:1.0 non construite (lancer : docker compose build attacker)."
fi

# Bilan 
bilan
exit_code