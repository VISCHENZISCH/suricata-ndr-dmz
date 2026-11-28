#!/bin/sh
#Groupe 2 - Débogueur bout-en-bout du labo Suricata NDR DMZ
#Suit un traceur unique G2DBG-<ts> du point d'entrée (:8082) jusqu'au point
#  de sortie (EveBox, Loki, Grafana, Mailpit) et diagnostique tout maillon KO.

#  Usage :
#      ./scripts/debug-lab.sh [--step MAILLE] [--trigger-alert] [--bundle]
#
set -u

# Port Grafana parametrable : une autre pile peut deja occuper le 3000.
GRAFANA_URL="${GRAFANA_URL:-https://127.0.0.1:3000}"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
# shellcheck source=scripts/lib-client.sh
. "$SCRIPT_DIR/lib-client.sh"

STEP=""
TRIGGER_ALERT=0
BUNDLE=0
BUNDLE_FILE=""

usage() {
    cat <<'EOF'
Usage : debug-lab.sh [options]

  --step MAILLE     ne débugue qu'un maillon : dmz, capture, suricata, evebox, loki, alerting
  --trigger-alert   envoie une SQLi sév.1 et attend le déclenchement Grafana -> Mailpit (~45 s)
  --bundle          exporte un rapport complet anonymisé dans /tmp/g2-debug-<horodatage>.log
  --no-banner       n'affiche pas l'en-tête
  -h, --help        affiche cette aide
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --step)          shift; [ $# -gt 0 ] || { printf -- '--step attend un nom\n' >&2; exit 2; }; STEP="$1" ;;
        --step=*)        STEP="${1#--step=}" ;;
        --trigger-alert) TRIGGER_ALERT=1 ;;
        --bundle)        BUNDLE=1 ;;
        --no-banner)     NO_BANNER=1 ;;
        -h|--help)       usage; exit 0 ;;
        *)               printf 'Option inconnue : %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if [ -n "$STEP" ]; then
    case "$STEP" in
        dmz|capture|suricata|evebox|loki|alerting) ;;
        *) printf 'Maillon inconnu : %s\n' "$STEP" >&2; usage >&2; exit 2 ;;
    esac
fi

want_step() { [ -z "$STEP" ] || [ "$STEP" = "$1" ]; }

# Charge les variables .env sans jamais les afficher
if [ -f .env ]; then
    set -a
    # shellcheck disable=SC1091
    . ./.env
    set +a
else
    fail "Fichier .env absent : impossible d'interroger EveBox/Grafana."
fi

load_docker
if [ "$DOCKER_OK" -eq 0 ]; then
    fail "Daemon Docker inaccessible : lancer Docker puis relancer."
    exit 1
fi

if [ "$BUNDLE" -eq 1 ]; then
    BUNDLE_FILE="/tmp/g2-debug-$(date +%Y%m%d-%H%M%S).log"
    : > "$BUNDLE_FILE"
fi

log_diag() {
    title="$1"; shift
    if [ -n "$BUNDLE_FILE" ]; then
        {
            printf '\n=== %s ===\n' "$title"
            "$@" 2>&1 || true
        } >> "$BUNDLE_FILE"
    fi
}

show_logs_tail() {
    cname="$1"; lines="${2:-15}"
    printf '    %s--- logs récents %s ---%s\n' "$DIM" "$cname" "$RESET"
    $T docker logs --tail "$lines" "$cname" 2>&1 | sed 's/^/    | /'
    log_diag "logs $cname" $T docker logs --tail 40 "$cname"
}

TRACE_ID="G2DBG-$(date +%s)-$$"
TRACE_SENT=0
SURICATA_IFACE=""

send_trace_probe() {
    [ "$TRACE_SENT" -eq 0 ] || return 0
    have curl || return 1
    TRACE_SENT=1
    info "Injection du traceur canonique : $TRACE_ID"
    curl -s -o /dev/null --max-time 4 -A "sqlmap/1.8.2-${TRACE_ID}" \
        "http://127.0.0.1:8082/?dbg=${TRACE_ID}" || true
}

# 1. Maillon DMZ : hôte :8082 -> web (nginx) -> api (FastAPI) -> db (Postgres)

dbg_dmz() {
    section "1. Maillon DMZ (hôte :8082 -> web -> api -> db)"
    if ! have curl; then fail "curl requis pour tester les endpoints."; return; fi

    c_web=$(curl -s -o /dev/null --max-time 4 -w '%{http_code}' http://127.0.0.1:8082/ || echo 000)
    if [ "$c_web" = "200" ]; then
        ok "web (Nginx :8082) répond HTTP 200."
    else
        fail "web (Nginx :8082) -> HTTP $c_web."
        show_logs_tail g2-web 15
    fi

    health_body=$(curl -s --max-time 4 http://127.0.0.1:8082/api/health || true)
    if printf '%s' "$health_body" | grep -q '"db":"up"'; then
        ok "Chaîne web -> api -> db opérationnelle ($health_body)."
    else
        fail "Chaîne /api/health en échec (réponse : ${health_body:-vide})."
        $T docker exec g2-web wget -qO- --timeout=3 http://api:8000/api/health >/dev/null 2>&1 \
            && info "web -> api:8000 joignable en interne." \
            || warn "web ne joint pas api:8000 en interne (vérifier DNS/réseau dmz)."
        $T docker exec g2-db pg_isready -U g2user -d g2db >/dev/null 2>&1 \
            && info "PostgreSQL g2-db prêt (pg_isready OK)." \
            || warn "PostgreSQL g2-db non prêt."
        show_logs_tail g2-api 15
    fi

    c_me=$(curl -s -o /dev/null --max-time 4 -w '%{http_code}' http://127.0.0.1:8082/api/me || echo 000)
    [ "$c_me" = "401" ] && ok "Endpoint protégé /api/me -> HTTP 401 attendu." || warn "/api/me -> HTTP $c_me (attendu 401)."
}

# 2. Maillon Capture : bridge br-xxxx (172.20.0.1) -> Suricata af-packet

dbg_capture() {
    section "2. Maillon Capture (bridge DMZ -> Suricata af-packet)"
    if ! printf '%s\n' "$DOCKER_PS" | grep -q '^g2-suricata|'; then
        if ! $T docker inspect -f '{{.State.Running}}' g2-suricata 2>/dev/null | grep -qx true; then
            fail "g2-suricata n'est pas démarré."
            show_logs_tail g2-suricata 20
            return
        fi
    fi

    SURICATA_IFACE=$($T docker exec g2-suricata sh -c \
        "ip -o -4 addr show | awk '\$4 ~ /^172\.20\.0\.1\// {print \$2; exit}'" 2>/dev/null || true)
    if [ -z "$SURICATA_IFACE" ]; then
        fail "Aucun bridge portant 172.20.0.1 trouvé."
        return
    fi
    ok "Bridge DMZ localisé : $SURICATA_IFACE (172.20.0.1/24)."

    ifaces_json=$($T docker exec g2-suricata suricatasc -c iface-list 2>/dev/null || true)
    if printf '%s' "$ifaces_json" | grep -q "\"$SURICATA_IFACE\""; then
        ok "Suricata écoute activement sur le bridge actuel ($SURICATA_IFACE)."
    else
        fail "Désynchronisation bridge/sonde : Suricata écoute '${ifaces_json:-?}' au lieu de '$SURICATA_IFACE' -> docker compose restart suricata."
    fi

    if $T docker exec g2-suricata ip link show dev "$SURICATA_IFACE" 2>/dev/null | grep -q 'PROMISC'; then
        ok "Mode PROMISC actif sur $SURICATA_IFACE."
    else
        fail "Mode PROMISC inactif sur $SURICATA_IFACE : Suricata rate le trafic inter-conteneurs -> restart suricata."
    fi

    # Mesure de compteurs de capture avant/après une requête témoin
    stat_before=$($T docker exec g2-suricata suricatasc -c "iface-stat $SURICATA_IFACE" 2>/dev/null || true)
    pkts_before=$(printf '%s' "$stat_before" | sed -n 's/.*"pkts": *\([0-9]*\).*/\1/p')
    send_trace_probe
    sleep 1
    stat_after=$($T docker exec g2-suricata suricatasc -c "iface-stat $SURICATA_IFACE" 2>/dev/null || true)
    pkts_after=$(printf '%s' "$stat_after" | sed -n 's/.*"pkts": *\([0-9]*\).*/\1/p')
    drops_after=$(printf '%s' "$stat_after" | sed -n 's/.*"drop": *\([0-9]*\).*/\1/p')

    if [ -n "$pkts_before" ] && [ -n "$pkts_after" ]; then
        delta=$((pkts_after - pkts_before))
        if [ "$delta" -gt 0 ]; then
            ok "Compteurs af-packet actifs (+$delta paquets capturés, total=$pkts_after, drops=${drops_after:-0})."
        else
            fail "Aucun paquet capturé pendant la sonde (+0 paquet sur $SURICATA_IFACE)."
            show_logs_tail g2-suricata 20
        fi
    else
        warn "Statistiques iface-stat illisibles (${stat_after:-vide})."
    fi
}

#  3. Maillon Détection Suricata : règles -> eve.json

dbg_suricata() {
    section "3. Maillon Détection Suricata (traceur dans eve.json)"
    send_trace_probe || { fail "curl requis pour injecter le traceur."; return; }

    found_http=0
    found_alert=0
    i=0
    while [ "$i" -lt 6 ]; do
        matches=$($T docker exec g2-suricata grep -F "$TRACE_ID" /var/log/suricata/eve.json 2>/dev/null || true)
        printf '%s\n' "$matches" | grep -q '"event_type":"http"'  && found_http=1
        printf '%s\n' "$matches" | grep -q '"event_type":"alert"' && found_alert=1
        [ "$found_http" -eq 1 ] && [ "$found_alert" -eq 1 ] && break
        sleep 1
        i=$((i + 1))
    done

    if [ "$found_http" -eq 1 ] && [ "$found_alert" -eq 1 ]; then
        ok "Traceur $TRACE_ID journalisé en HTTP et détecté en alerte dans eve.json."
    elif [ "$found_http" -eq 1 ]; then
        fail "Traceur vu en HTTP mais AUCUNE alerte générée (vérifier HOME_NET, HTTP_PORTS et local.rules)."
        $T docker exec g2-suricata suricata -T -c /etc/suricata/suricata.yaml 2>&1 | tail -n 15 | sed 's/^/    | /'
    else
        fail "Traceur absent de eve.json (problème de capture af-packet ou checksum)."
        show_logs_tail g2-suricata 20
    fi
}


#  4. Maillon EveBox : volume partagé eve.json -> SQLite -> :5636

dbg_evebox() {
    section "4. Maillon EveBox (volume eve.json -> SQLite -> :5636)"
    if [ "$TRACE_SENT" -eq 0 ]; then
        send_trace_probe && sleep 2
    fi
    if $T docker exec g2-evebox grep -qF "$TRACE_ID" /var/log/suricata/eve.json 2>/dev/null; then
        ok "g2-evebox voit bien le traceur $TRACE_ID dans le volume partagé eve.json."
    else
        fail "g2-evebox ne voit pas $TRACE_ID dans /var/log/suricata/eve.json (vérifier le montage suricata-logs)."
    fi

    if have curl; then
        ping_code=$(curl -sk -o /dev/null --max-time 4 -w '%{http_code}' https://127.0.0.1:5636/ping || echo 000)
        api_code=$(curl -sk -o /dev/null --max-time 4 -w '%{http_code}' https://127.0.0.1:5636/api/alerts || echo 000)
        if [ "$ping_code" = "200" ] && [ "$api_code" = "401" ]; then
            ok "EveBox HTTPS prêt (/ping=200, /api/alerts=401 protégé)."
        elif [ "$ping_code" = "200" ]; then
            warn "EveBox /ping=200, mais /api/alerts=$api_code (attendu 401)."
        else
            fail "EveBox injoignable (/ping=$ping_code)."
        fi
    fi

    err_eve=$($T docker logs --tail 30 g2-evebox 2>&1 | grep -iE 'error|fatal|locked|denied' | grep -v 'GeoIP' || true)
    if [ -n "$err_eve" ]; then
        warn "Messages d'erreur récents dans g2-evebox :"
        printf '%s\n' "$err_eve" | sed 's/^/    | /'
    else
        ok "Aucune erreur SQLite/lecteur récente dans g2-evebox."
    fi
}


#  5. Maillon Observabilité : Promtail -> Loki -> Grafana

dbg_loki() {
    section "5. Maillon Observabilité (Promtail -> Loki -> Grafana)"

    # Vérifier l'isolation réseau (monitoring uniquement, pas dmz)
    for c in g2-promtail g2-loki g2-grafana; do
        nets=$($T docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$c" 2>/dev/null || true)
        case "$nets" in
            *dmz*) fail "$c est rattaché au réseau DMZ ($nets) : risque d'alerte en boucle !" ;;
            *monitoring*) ok "$c isolé sur le réseau monitoring." ;;
            *) warn "$c : réseau inattendu ($nets)." ;;
        esac
    done

    # Position Promtail vs taille eve.json
    eve_bytes=$($T docker exec g2-suricata sh -c 'wc -c < /var/log/suricata/eve.json' 2>/dev/null | tr -d '[:space:]' || echo 0)
    pos_bytes=$($T docker exec g2-promtail sed -n 's/.*eve\.json: *"\?\([0-9]*\)"\?.*/\1/p' /positions/positions.yaml 2>/dev/null | head -n 1 || echo "")
    if [ -n "$pos_bytes" ]; then
        lag=$((eve_bytes - pos_bytes))
        [ "$lag" -lt 0 ] && lag=0
        if [ "$lag" -lt 65536 ]; then
            ok "Promtail à jour sur eve.json (taille=${eve_bytes} o, offset=${pos_bytes} o, retard=${lag} o)."
        else
            warn "Promtail en retard sur eve.json (retard=${lag} o)."
            show_logs_tail g2-promtail 15
        fi
    else
        warn "Offset Promtail illisible dans /positions/positions.yaml."
        show_logs_tail g2-promtail 15
    fi

    if ! have curl || [ -z "${GRAFANA_ADMIN_USER:-}" ] || [ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]; then
        warn "curl ou identifiants Grafana manquants : test de requête Loki ignoré."
        return
    fi

    auth="${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}"
    send_trace_probe || true

    # Attend jusqu'à 10 s que Promtail pousse $TRACE_ID dans Loki
    loki_hit=0
    i=0
    while [ "$i" -lt 10 ]; do
        resp=$(curl -sk --max-time 5 -u "$auth" -H "Content-Type: application/json" \
            -d "{\"queries\":[{\"refId\":\"A\",\"datasource\":{\"type\":\"loki\",\"uid\":\"loki\"},\"expr\":\"sum(count_over_time({job=\\\"suricata\\\",event_type=\\\"alert\\\"} |= \\\"${TRACE_ID}\\\" [15m]))\",\"queryType\":\"instant\"}],\"from\":\"now-15m\",\"to\":\"now\"}" \
            ${GRAFANA_URL}/api/ds/query || true)
        if printf '%s' "$resp" | grep -q '"values":\[\[[0-9]*\],\[[1-9]'; then
            loki_hit=1; break
        fi
        sleep 1
        i=$((i + 1))
    done

    if [ "$loki_hit" -eq 1 ]; then
        ok "Traceur $TRACE_ID retrouvé dans Loki via Grafana en ~${i} s."
    else
        fail "Traceur $TRACE_ID introuvable dans Loki via Grafana après 10 s."
        show_logs_tail g2-promtail 15
        show_logs_tail g2-loki 15
    fi

    # Test d'une requête de chaque dashboard
    for label_q in "direction:sum by (severity) (count_over_time({job=\\\"suricata\\\",event_type=\\\"alert\\\"}[1h]))" \
                   "exploitation:sum(count_over_time({job=\\\"suricata\\\",event_type=\\\"http\\\"}[1h]))"; do
        name="${label_q%%:*}"
        expr="${label_q#*:}"
        r=$(curl -sk --max-time 5 -u "$auth" -H "Content-Type: application/json" \
            -d "{\"queries\":[{\"refId\":\"A\",\"datasource\":{\"type\":\"loki\",\"uid\":\"loki\"},\"expr\":\"${expr}\",\"queryType\":\"instant\"}],\"from\":\"now-1h\",\"to\":\"now\"}" \
            ${GRAFANA_URL}/api/ds/query || true)
        if printf '%s' "$r" | grep -q '"status":200'; then
            ok "Requête dashboard $name valide (HTTP/Loki 200)."
        else
            fail "Requête dashboard $name en échec."
        fi
    done
}

# 6. Maillon Sortie : Grafana Alerting -> Mailpit (:8025)
dbg_alerting() {
    section "6. Maillon Alerting & Sortie (Grafana Alerting -> Mailpit)"
    if ! have curl || [ -z "${GRAFANA_ADMIN_USER:-}" ] || [ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]; then
        warn "curl ou identifiants Grafana manquants : maillon alerting ignoré."
        return
    fi

    auth="${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}"
    rules_state=$(curl -sk --max-time 5 -u "$auth" ${GRAFANA_URL}/api/prometheus/grafana/api/v1/rules || true)
    if have python3 && [ -n "$rules_state" ]; then
        PY_RULES='
import json, sys
try:
    d = json.load(sys.stdin)
    groups = d.get("data", {}).get("groups", [])
    total = 0
    errs = 0
    for g in groups:
        for r in g.get("rules", []):
            total += 1
            rname = r.get("name", "?")
            st = r.get("state", "?")
            hl = r.get("health", "?")
            print(f"RULE:{rname}|{st}|{hl}")
            if hl != "ok":
                errs += 1
    print(f"SUMMARY:{total}|{errs}")
except Exception as e:
    print(f"ERR:{e}")
'
        parsed=$(printf '%s' "$rules_state" | python3 -I -c "$PY_RULES" 2>/dev/null || true)
        summary=$(printf '%s\n' "$parsed" | grep '^SUMMARY:' | head -n 1)
        if [ -n "$summary" ]; then
            total_r=$(printf '%s' "$summary" | cut -d: -f2 | cut -d'|' -f1)
            err_r=$(printf '%s' "$summary" | cut -d'|' -f2)
            printf '%s\n' "$parsed" | grep '^RULE:' | while IFS='|' read -r lhs st hl; do
                rname="${lhs#RULE:}"
                info "Règle '$rname' -> state=$st, health=$hl"
            done
            if [ "${err_r:-0}" -eq 0 ] && [ "${total_r:-0}" -ge 4 ]; then
                ok "$total_r règles d'alerte saines (health=ok)."
            elif [ "${err_r:-0}" -gt 0 ]; then
                fail "$err_r règle(s) d'alerte en erreur d'évaluation."
                show_logs_tail g2-grafana 20
            else
                warn "Seulement ${total_r:-0} règle(s) détectée(s)."
            fi
        else
            warn "Réponse /api/prometheus/grafana/api/v1/rules illisible."
        fi
    else
        warn "python3 absent ou API règles injoignable."
    fi

    if [ -n "${MAILPIT_RELAY_CONFIG:-}" ]; then
        if [ -z "${GMAIL_USER:-}" ] || [ -z "${GMAIL_APP_PASSWORD:-}" ]; then
            warn "MAILPIT_RELAY_CONFIG est défini mais GMAIL_USER ou GMAIL_APP_PASSWORD est vide."
        elif [ -z "${MAILPIT_RELAY_MATCHING:-}" ]; then
            warn "MAILPIT_RELAY_CONFIG est défini sans MAILPIT_RELAY_MATCHING : aucun envoi automatique ne sera relayé."
        else
            ok "Relais SMTP Mailpit configuré (${MAILPIT_RELAY_CONFIG}, filtre ${MAILPIT_RELAY_MATCHING})."
        fi
    fi

    mp_before=$(curl -s --max-time 4 http://127.0.0.1:8025/api/v1/messages || true)
    mp_count=$(printf '%s' "$mp_before" | sed -n 's/.*"total":\([0-9]*\).*/\1/p')
    if [ -n "$mp_count" ]; then
        ok "Mailpit joignable ($mp_count message(s) en boîte)."
    else
        fail "Mailpit (:8025) injoignable."
        show_logs_tail g2-mailpit 15
        return
    fi

    if [ "$TRIGGER_ALERT" -eq 1 ]; then
        info "--trigger-alert : injection SQLi sévérité 1 + attente notification Mailpit (max 50 s)..."
        curl -s -o /dev/null --max-time 4 \
            "http://127.0.0.1:8082/api/me?id=1%27%20UNION%20SELECT%20username,password%20FROM%20users--&dbg=${TRACE_ID}" || true
        got_mail=0
        t=0
        while [ "$t" -lt 50 ]; do
            mp_now=$(curl -s --max-time 4 http://127.0.0.1:8025/api/v1/messages || true)
            now_count=$(printf '%s' "$mp_now" | sed -n 's/.*"total":\([0-9]*\).*/\1/p')
            if [ -n "$now_count" ] && [ "$now_count" -gt "${mp_count:-0}" ]; then
                got_mail=1; break
            fi
            sleep 2
            t=$((t + 2))
        done
        if [ "$got_mail" -eq 1 ]; then
            ok "Notification réelle reçue dans Mailpit en ~${t} s (total=$now_count) !"
        else
            fail "Aucun nouvel e-mail reçu dans Mailpit après 50 s."
            show_logs_tail g2-grafana 25
        fi
    fi
}

# Exécution
if [ -z "$NO_BANNER" ]; then
    printf '\n\n%s' "$ORANGE"
    cat <<'ART'
     888          888                                    888          888      
     888          888                                    888          888      
     888          888                                    888          888      
 .d88888  .d88b.  88888b.  888  888  .d88b.              888  8888b.  88888b.  
d88" 888 d8P  Y8b 888 "88b 888  888 d88P"88b             888     "88b 888 "88b 
888  888 88888888 888  888 888  888 888  888 888888      888 .d888888 888  888 
Y88b 888 Y8b.     888 d88P Y88b 888 Y88b 888             888 888  888 888 d88P 
 "Y88888  "Y8888  88888P"   "Y88888  "Y88888             888 "Y888888 88888P"  
                                         888                                   
                                    Y8b d88P                                   
                                     "Y88P"                                    
ART
    printf '%s  %sGroupe 2 · Débogueur bout-en-bout (%s)%s\n\n\n' "$RESET" "$DIM" "$TRACE_ID" "$RESET"
fi

want_step dmz      && dbg_dmz
want_step capture  && dbg_capture
want_step suricata && dbg_suricata
want_step evebox   && dbg_evebox
want_step loki     && dbg_loki
want_step alerting && dbg_alerting

if [ -n "$BUNDLE_FILE" ]; then
    log_diag "docker compose ps" $T docker compose ps
    log_diag "ip addr" ip -o -4 addr show
    log_diag "suricata -T" $T docker exec g2-suricata suricata -T -c /etc/suricata/suricata.yaml
    info "Bundle de diagnostic enregistré : $BUNDLE_FILE"
fi

bilan "Chaîne bout-en-bout saine" "Chaîne fonctionnelle avec avertissements" "Rupture détectée dans la chaîne"
[ "$FAIL" -eq 0 ]
