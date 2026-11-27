#!/bin/sh
#  Groupe 2 - Bibliothèque commune pour check-linux.sh et check-wsl.sh


PASS=0
WARN=0
FAIL=0
STRICT=0
FIX=0
NO_INTERNET=0
NO_SUDO=0
ONLY=""
NO_BANNER="${NO_BANNER:-}"

SKEW_WARN="${SKEW_WARN:-2}"
SKEW_FAIL="${SKEW_FAIL:-30}"
NTP_SERVERS="${NTP_SERVERS:-pool.ntp.org time.cloudflare.com time.google.com}"
TIME_URLS="${TIME_URLS:-https://www.cloudflare.com/cdn-cgi/trace https://www.google.com/generate_204}"
LAB_URL="${LAB_URL:-https://127.0.0.1:3000/api/health}"
LAB_PORTS="${LAB_PORTS:-8082 5636 3000 8025}"
DMZ_GW="${DMZ_GW:-172.20.0.1}"
DMZ_SUBNET="${DMZ_SUBNET:-172.20.0.0/16}"
LAB_NET_REGEX="${LAB_NET_REGEX:-g2|dmz}"
DISK_WARN_MB="${DISK_WARN_MB:-5120}"
DISK_FAIL_MB="${DISK_FAIL_MB:-1024}"
INODE_WARN_PCT="${INODE_WARN_PCT:-90}"
REQUIRED_TOOLS="${REQUIRED_TOOLS:-curl git docker python3}"
OPTIONAL_TOOLS="${OPTIONAL_TOOLS:-nmap hping3 jq nc tcpdump ethtool ss ip}"

CLOCK_BAD=0
NTP_DAEMON_OK=0
UDP123_OK=0
HAS_SYSTEMD=0
BEST_OFFSET=""
BEST_SRC=""
DOCKER_LOADED=0
DOCKER_OK=0
DOCKER_PS=""
COMPOSE_CFG=""
COMPOSE_V2=0
DISK_SEEN=" "

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    BOLD=$(printf '\033[1m'); DIM=$(printf '\033[2m')
    BRED=$(printf '\033[1;91m'); BGREEN=$(printf '\033[1;92m')
    BYELLOW=$(printf '\033[1;93m'); BBLUE=$(printf '\033[1;94m')
    case "${TERM:-}" in
        *256color*|xterm*|tmux*|screen*|alacritty|kitty) ORANGE=$(printf '\033[1;38;5;208m') ;;
        *) ORANGE=$(printf '\033[1;97m') ;;
    esac
    RESET=$(printf '\033[0m')
else
    BOLD=; DIM=; BRED=; BGREEN=; BYELLOW=; BBLUE=; ORANGE=; RESET=
fi

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd) || exit 1
cd "$ROOT" || exit 1

TMPD=$(mktemp -d 2>/dev/null) || { TMPD="/tmp/check-client.$$"; mkdir -p "$TMPD" || TMPD=""; }
cleanup() { [ -n "$TMPD" ] && rm -rf "$TMPD"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

have() { command -v "$1" >/dev/null 2>&1; }

T=""
have timeout && T="timeout 15"

section() { printf '\n%s==> %s%s\n' "$BBLUE" "$1" "$RESET"; }
ok()      { PASS=$((PASS + 1)); printf '  %s[OK]%s   %s\n' "$BGREEN"  "$RESET" "$1"; }
warn()    { WARN=$((WARN + 1)); printf '  %s[WARN]%s %s\n' "$BYELLOW" "$RESET" "$1"; }
fail()    { FAIL=$((FAIL + 1)); printf '  %s[FAIL]%s %s\n' "$BRED"    "$RESET" "$1"; }
info()    { printf '  %s[INFO]%s %s\n' "$DIM" "$RESET" "$1"; }

want() {
    [ -z "$ONLY" ] && return 0
    case ",$ONLY," in *",$1,"*) return 0 ;; *) return 1 ;; esac
}

to_int() {
    v=$(printf '%s\n' "${1:-}" | head -n 1 | tr -d '[:space:]')
    case "$v" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$v" ;; esac
}

is_num() {
    case "${1:-}" in ''|*[!0-9.-]*|-|.|*-*-*) return 1 ;; *) return 0 ;; esac
}

abs_le()    { awk -v a="$1" -v b="$2" 'BEGIN { if (a < 0) a = -a; exit !(a <= b) }'; }
round_int() { awk -v x="$1" 'BEGIN { printf "%d", (x >= 0) ? x + 0.5 : x - 0.5 }'; }
ver_ge()    { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" = "$2" ]; }
read_sysctl() { cat "/proc/sys/$(printf '%s' "$1" | tr . /)" 2>/dev/null; }

pkg_of() {
    case "$1" in
        ss|ip) printf 'iproute2' ;;
        nc)    printf 'netcat-openbsd' ;;
        *)     printf '%s' "$1" ;;
    esac
}

parse_common_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --fix)         FIX=1 ;;
            --no-internet) NO_INTERNET=1 ;;
            --no-sudo)     NO_SUDO=1 ;;
            --strict)      STRICT=1 ;;
            --no-banner)   NO_BANNER=1 ;;
            --only)        shift; [ $# -gt 0 ] || { printf -- '--only attend une liste de sections\n' >&2; exit 2; }; ONLY="$1" ;;
            --only=*)      ONLY="${1#--only=}" ;;
            -h|--help)     usage; exit 0 ;;
            *)             printf 'Option inconnue : %s\n' "$1" >&2; usage >&2; exit 2 ;;
        esac
        shift
    done
    if [ -n "$ONLY" ]; then
        for s in $(printf '%s' "$ONLY" | tr ',' ' '); do
            case "$s" in
                env|clock|net|docker|ports|tools|disk|host) ;;
                *) printf 'Section inconnue : %s\n' "$s" >&2; usage >&2; exit 2 ;;
            esac
        done
    fi
}

SUDO_MODE=none
init_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        SUDO_MODE=root
    elif [ "$NO_SUDO" -eq 0 ] && have sudo && sudo -n true 2>/dev/null; then
        SUDO_MODE=sudo
    fi
    [ "$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ')" = "systemd" ] && HAS_SYSTEMD=1
}

priv() {
    case "$SUDO_MODE" in
        root) "$@" ;;
        sudo) sudo -n "$@" ;;
        *)    return 126 ;;
    esac
}

load_docker() {
    [ "$DOCKER_LOADED" -eq 0 ] || return 0
    DOCKER_LOADED=1
    have docker || return 0
    if $T docker info >/dev/null 2>&1; then
        DOCKER_OK=1
        DOCKER_PS=$($T docker ps --format '{{.Names}}|{{.Ports}}' 2>/dev/null) || DOCKER_PS=""
    fi
    if docker compose version >/dev/null 2>&1; then
        COMPOSE_V2=1
        COMPOSE_CFG=$($T docker compose config 2>/dev/null) || COMPOSE_CFG=""
    fi
}

lab_running() { printf '%s\n' "$DOCKER_PS" | grep -q '^g2-'; }

# Helpers communs : environnement & temps 
check_common_env() {
    case "$SUDO_MODE" in
        root) ok "Exécuté en root : contrôles complets (processus des ports, pare-feu)." ;;
        sudo) ok "sudo sans mot de passe disponible : contrôles complets." ;;
        *)    info "Ni root ni sudo sans mot de passe : relancer avec sudo pour voir les processus des ports." ;;
    esac

    crlf=""; cr=$(printf '\r')
    for f in .env scripts/*.sh docker-compose*.yml docker-compose*.yaml compose*.yml; do
        [ -f "$f" ] || continue
        grep -q "$cr" "$f" 2>/dev/null && crlf="$crlf $f"
    done
    if [ -n "$crlf" ]; then fail "Fins de ligne Windows (CRLF) dans :$crlf -> sed -i 's/\\r\$//' <fichier>"
    else ok "Aucun CRLF dans .env, scripts/*.sh et fichiers compose."; fi

    if [ -f .env ]; then
        perm=$(stat -c '%a' .env 2>/dev/null || echo "")
        case "$perm" in
            ''|*00) [ -n "$perm" ] && ok ".env non lisible par les autres (permissions $perm)." ;;
            *)      warn ".env lisible par d'autres utilisateurs (permissions $perm) -> chmod 600 .env" ;;
        esac
    fi
}

http_offset() {
    t0=$(date +%s)
    hdr=$(curl -sk -D - -o /dev/null --connect-timeout 3 -m 6 "$1" 2>/dev/null | tr -d '\r' | grep -i '^date:' | head -n 1) || true
    t1=$(date +%s)
    [ -n "$hdr" ] || return 1
    ref=$(date -u -d "${hdr#*: }" +%s 2>/dev/null) || return 1
    printf '%s' $((ref - (t0 + t1) / 2))
}

PY_SNTP='
import socket, struct, sys, time
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(3)
    t0 = time.time()
    s.sendto(b"\x1b" + 47 * b"\0", (sys.argv[1], 123))
    data, _ = s.recvfrom(48)
    t1 = time.time()
    w = struct.unpack("!12I", data)
    srv = (w[10] - 2208988800) + w[11] / 2.0 ** 32
    print("%.3f" % (srv - (t0 + t1) / 2))
except Exception:
    sys.exit(1)
'

sntp_offset() {
    have python3 || return 1
    out=$($T python3 -I -c "$PY_SNTP" "$1" 2>/dev/null) || return 1
    is_num "$out" || return 1
    printf '%s' "$out"
}

PY_OVERLAP='
import ipaddress, sys
net = ipaddress.ip_network(sys.argv[1], strict=False)
for line in sys.stdin:
    p = line.split()
    if len(p) < 2: continue
    try: other = ipaddress.ip_network(p[0], strict=False)
    except ValueError: continue
    if other.version == net.version and net.overlaps(other):
        print(p[0], p[1])
'

skew_check() {
    label="$1"; off="$2"
    a=$(awk -v x="$off" 'BEGIN { if (x < 0) x = -x; printf "%.2f", x }')
    dir=$(awk -v x="$off" 'BEGIN { print (x > 0) ? "en retard" : "en avance" }')
    if abs_le "$off" "$SKEW_WARN"; then
        ok "Horloge vs $label : écart ${a}s (tolérance ${SKEW_WARN}s)."
    elif abs_le "$off" "$SKEW_FAIL"; then
        warn "Horloge vs $label : écart ${a}s, le client est $dir."
        CLOCK_BAD=1
    else
        fail "Horloge vs $label : écart ${a}s, le client est $dir (OTP/TLS/horodatages compromis)."
        CLOCK_BAD=1
    fi
}

tcp_open() {
    if have python3; then
        $T python3 -I -c 'import socket,sys; s=socket.create_connection((sys.argv[1],int(sys.argv[2])),3); s.close()' "$1" "$2" >/dev/null 2>&1
    elif have nc; then
        nc -z -w 3 "$1" "$2" >/dev/null 2>&1
    else
        curl -s -o /dev/null --connect-timeout 3 -m 4 "http://$1:$2/" >/dev/null 2>&1
        rc=$?; [ "$rc" -ne 7 ] && [ "$rc" -ne 28 ] && [ "$rc" -ne 6 ]
    fi
}

check_common_clock_refs() {
    if [ -f "$TMPD/lab" ]; then skew_check "labo (HTTP Date de $LAB_URL)" "$(cat "$TMPD/lab")"
    else info "Labo injoignable sur $LAB_URL : écart vs labo non mesuré."; fi

    load_docker
    if [ "$DOCKER_OK" -eq 1 ]; then
        for c in g2-suricata g2-grafana; do
            if printf '%s\n' "$DOCKER_PS" | grep -q "^$c|"; then
                t0=$(date +%s)
                ce=$($T docker exec "$c" date -u +%s 2>/dev/null | tr -d '\r\n ') || true
                t1=$(date +%s)
                case "$ce" in
                    ''|*[!0-9]*) info "$c : heure du conteneur illisible." ;;
                    *) skew_check "conteneur $c" $((ce - (t0 + t1) / 2)) ;;
                esac
            fi
        done
    fi

    if [ "$NO_INTERNET" -eq 1 ]; then
        info "--no-internet : tests Internet et NTP ignorés."
        return
    fi
    if [ -f "$TMPD/inet" ]; then
        read -r u off < "$TMPD/inet"
        skew_check "Internet ($(printf '%s' "$u" | sed 's|https\{0,1\}://\([^/]*\).*|\1|'))" "$off"
    elif have curl; then
        warn "Aucun repère de temps Internet joignable en HTTP(S)."
    fi

    if have python3; then
        sntp_ok=""; first=""
        for f in "$TMPD"/sntp.*; do
            [ -f "$f" ] || continue
            read -r srv off < "$f"
            sntp_ok="$sntp_ok $srv"
            [ -n "$first" ] || first="$srv $off"
        done
        if [ -n "$sntp_ok" ]; then
            UDP123_OK=1
            set -- $first
            skew_check "NTP $1" "$2"
            ok "UDP 123 sortant ouvert (réponses de :$sntp_ok)."
        else
            warn "UDP 123 sortant bloqué ou DNS KO : chrony/ntpd ne pourront pas se synchroniser."
            CLOCK_BAD=1
            if tcp_open time.cloudflare.com 4460; then
                ok "TCP 4460 (NTS) joignable : chrony peut synchroniser en NTS."
            else
                info "TCP 4460 (NTS) également filtré : utiliser --fix."
            fi
        fi
    else
        warn "python3 absent : test SNTP (UDP 123) impossible."
    fi
}

check_ntp_daemons() {
    if [ "$HAS_SYSTEMD" -eq 1 ] && have timedatectl; then
        sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
        ntp_on=$(timedatectl show -p NTP --value 2>/dev/null || true)
        case "$sync" in
            yes) ok "timedatectl : horloge synchronisée (NTPSynchronized=yes)."; NTP_DAEMON_OK=1 ;;
            no)  warn "timedatectl : horloge NON synchronisée (NTP=${ntp_on:-?})."; CLOCK_BAD=1 ;;
            *)   warn "timedatectl : état de synchronisation illisible." ;;
        esac
    fi
    daemons=""; ndaemons=0
    for d in chronyd ntpd; do
        if pgrep -x "$d" >/dev/null 2>&1; then daemons="$daemons $d"; ndaemons=$((ndaemons + 1)); fi
    done
    if pgrep -f systemd-timesyncd >/dev/null 2>&1; then daemons="$daemons systemd-timesyncd"; ndaemons=$((ndaemons + 1)); fi
    if [ "$ndaemons" -ge 2 ]; then
        warn "Plusieurs démons de temps actifs (${daemons# }) : n'en garder qu'un (chrony recommandé)."
        NTP_DAEMON_OK=1
    elif [ "$ndaemons" -eq 1 ]; then
        ok "Démon de temps actif :$daemons."
        NTP_DAEMON_OK=1
    else
        warn "Aucun démon NTP actif (chronyd / ntpd / systemd-timesyncd)."
        CLOCK_BAD=1
    fi
    if have chronyc && pgrep -x chronyd >/dev/null 2>&1; then
        ct=$($T chronyc tracking 2>/dev/null | grep -E '^(System time|Leap status)' | tr '\n' ';' | sed 's/  */ /g') || true
        [ -n "$ct" ] && info "chrony : $ct"
    fi
}

# Sections communes : net, docker, ports, tools, disk 
sec_net() {
    section "3. Réseau client"
    if have ip; then
        route_line=$(ip -4 route show default 2>/dev/null | head -n 1)
        if [ -n "$route_line" ]; then
            ok "Route par défaut : $route_line"
            dev=$(printf '%s' "$route_line" | sed -n 's/.* dev \([^ ]*\).*/\1/p')
            if [ -n "$dev" ]; then
                mtu=$(to_int "$(ip -o link show dev "$dev" 2>/dev/null | sed -n 's/.* mtu \([0-9]*\).*/\1/p')")
                if [ "$mtu" -gt 0 ] && [ "$mtu" -lt 1400 ]; then
                    warn "MTU $mtu sur $dev (VPN ?) : paquets fragmentés possibles."
                elif [ "$mtu" -gt 0 ]; then
                    ok "MTU $dev = $mtu."
                fi
            fi
        else
            fail "Aucune route IPv4 par défaut."
        fi
    else
        warn "Commande ip absente (sudo apt install iproute2)."
    fi

    if [ -s /etc/resolv.conf ] && grep -q '^nameserver' /etc/resolv.conf; then
        ns=$(grep '^nameserver' /etc/resolv.conf | awk '{print $2}' | tr '\n' ' ')
        ok "DNS configurés : $ns"
        case "$ns" in *127.0.0.53*) info "Résolveur systemd-resolved (127.0.0.53)." ;; esac
    else
        fail "/etc/resolv.conf vide ou sans nameserver."
    fi

    proxy=""
    for v in HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy; do
        eval "val=\${$v:-}"; [ -n "$val" ] && proxy="$proxy $v"
    done
    if [ -n "$proxy" ]; then
        np="${NO_PROXY:-${no_proxy:-}}"
        case "$np" in
            *127.0.0.1*|*localhost*) ok "Proxy défini (${proxy# }) mais NO_PROXY exclut localhost." ;;
            *) warn "Proxy défini (${proxy# }) sans NO_PROXY pour 127.0.0.1/localhost." ;;
        esac
    else
        ok "Aucune variable de proxy dans l'environnement."
    fi

    if [ "$NO_INTERNET" -eq 0 ]; then
        if getent hosts rules.emergingthreats.net >/dev/null 2>&1; then ok "Résolution DNS fonctionnelle (rules.emergingthreats.net)."
        else fail "Résolution DNS en échec."; fi
        if have curl; then
            code=$(curl -s -o /dev/null --connect-timeout 3 -m 8 -w '%{http_code}' https://rules.emergingthreats.net/open/ 2>/dev/null) || true
            case "${code:-000}" in
                200|301|302) ok "Accès ET Open joignable (HTTP $code)." ;;
                000)         warn "rules.emergingthreats.net injoignable (update-rules échouera)." ;;
                *)           warn "rules.emergingthreats.net -> HTTP $code." ;;
            esac
        fi
    else
        info "--no-internet : DNS/Internet non testés."
    fi
}

sec_docker() {
    section "4. Docker"
    load_docker
    if ! have docker; then fail "Docker introuvable."; return; fi

    if [ "$DOCKER_OK" -eq 1 ]; then
        ok "Daemon Docker joignable (contexte : $(docker context show 2>/dev/null || echo '?'))."
        sv=$($T docker version -f '{{.Server.Version}}' 2>/dev/null) || sv=""
        if [ -n "$sv" ]; then
            if ver_ge "$sv" 20.10; then ok "Docker Engine $sv."; else fail "Docker Engine $sv trop ancien (>= 20.10 requis)."; fi
        fi
        secopt=$($T docker info -f '{{.SecurityOptions}}' 2>/dev/null) || secopt=""
        case "$secopt" in
            *rootless*) warn "Docker rootless : Suricata ne verra pas le bridge DMZ. Utiliser Docker rootful." ;;
        esac
    else
        fail "Daemon Docker inaccessible."
        if [ -S /var/run/docker.sock ] && [ "$(id -u)" -ne 0 ] && ! id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
            warn "Utilisateur absent du groupe docker : sudo usermod -aG docker \$USER"
        fi
    fi

    if [ "$COMPOSE_V2" -eq 1 ]; then
        cv=$(docker compose version --short 2>/dev/null)
        if ver_ge "${cv#v}" 2.0; then ok "Docker Compose v2 : ${cv}."; else warn "Docker Compose ${cv} ancien."; fi
    else
        fail "Docker Compose v2 introuvable."
    fi

    if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
        if [ -n "$COMPOSE_CFG" ]; then
            ok "Configuration Compose valide."
            if printf '%s\n' "$COMPOSE_CFG" | grep -Eq 'NET_RAW|privileged: true'; then
                ok "Compose accorde NET_RAW/privileged (capture Suricata)."
            else
                warn "Aucun cap_add NET_RAW / privileged dans le compose."
            fi
        elif [ "$COMPOSE_V2" -eq 1 ]; then
            fail "docker compose config en échec (.env manquant ou YAML invalide)."
        fi
    fi
}

listening_ports() {
    awk 'NR > 1 && $4 == "0A" { n = split($2, a, ":"); print a[n] }' /proc/net/tcp /proc/net/tcp6 2>/dev/null \
        | sort -u | while read -r h; do printf ' %d' "0x$h"; done
    printf ' '
}

port_owner() {
    p="$1"
    have ss || return 1
    priv ss -H -ltnp "sport = :$p" 2>/dev/null | sed -n 's/.*users:(("\([^"]*\)",pid=\([0-9]*\).*/\1(\2)/p' | head -n 1
}

sec_ports() {
    section "5. Ports du labo (libres ou occupés)"
    load_docker
    compose_ports=$(printf '%s\n' "$COMPOSE_CFG" | awk '/published:/ { gsub(/[" ]/, "", $2); print $2 }')
    ports=$(printf '%s %s\n' "$LAB_PORTS" "$compose_ports" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -un | tr '\n' ' ')
    listen=$(listening_ports)
    running=0; lab_running && running=1
    if [ "$running" -eq 1 ]; then info "Labo démarré : les ports doivent être servis par g2-*."
    else info "Labo arrêté : les ports doivent être libres."; fi

    for p in $ports; do
        is_listen=0
        case "$listen" in *" $p "*) is_listen=1 ;; esac
        cont=$(printf '%s\n' "$DOCKER_PS" | grep -F ":$p->" | cut -d'|' -f1 | head -n 1)
        if [ -n "$cont" ]; then
            case "$cont" in
                g2-*) ok "Port $p servi par le conteneur $cont." ;;
                *)    fail "Port $p occupé par le conteneur « $cont » (hors labo)." ;;
            esac
        elif [ "$is_listen" -eq 1 ]; then
            owner=$(port_owner "$p") || owner=""
            case "$owner" in
                docker-proxy*|dockerd*|com.docker*)
                    [ "$running" -eq 1 ] && ok "Port $p publié par Docker ($owner)." || warn "Port $p tenu par Docker ($owner) alors que le labo est arrêté." ;;
                '') [ "$DOCKER_OK" -eq 1 ] && fail "Port $p occupé (relancer avec sudo pour identifier)." || warn "Port $p occupé (Docker injoignable)." ;;
                *)  fail "Port $p occupé par $owner." ;;
            esac
        else
            [ "$running" -eq 1 ] && warn "Port $p libre alors que le labo tourne." || ok "Port $p libre."
        fi
    done
}

sec_tools() {
    section "6. Outils"
    for t in $REQUIRED_TOOLS; do
        if have "$t"; then ok "$t présent."; else fail "$t manquant (sudo apt install $(pkg_of "$t"))."; fi
    done
    for t in $OPTIONAL_TOOLS; do
        if have "$t"; then ok "$t présent."; else warn "$t absent (optionnel : sudo apt install $(pkg_of "$t"))."; fi
    done
    if have python3; then
        pv=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)
        [ -n "$pv" ] && { ver_ge "$pv" 3.8 && ok "Python $pv." || fail "Python $pv trop ancien (>= 3.8 requis)."; }
    fi
    if have apt-get; then
        locks=""
        for pr in unattended-upgr apt apt-get dpkg aptitude; do pgrep -x "$pr" >/dev/null 2>&1 && locks="$locks $pr"; done
        [ -n "$locks" ] && warn "Gestionnaire de paquets verrouillé (${locks# })." || ok "Aucun verrou apt/dpkg en cours."
    fi
}

disk_check() {
    label="$1"; path="$2"
    [ -e "$path" ] || return 0
    line=$(df -Pk "$path" 2>/dev/null | awk 'NR == 2 { print $1, $4, $5, $6 }')
    [ -n "$line" ] || { info "$label ($path) : df illisible."; return 0; }
    set -- $line; dev="$1"; avail_mb=$(( $2 / 1024 )); pct="$3"; mnt="$4"
    case "$DISK_SEEN" in *" $dev "*) info "$label ($path) : même volume ($mnt)."; return 0 ;; esac
    DISK_SEEN="$DISK_SEEN$dev "
    if [ "$avail_mb" -lt "$DISK_FAIL_MB" ]; then fail "$label ($mnt) : ${avail_mb} Mo libres (${pct} utilisé)."
    elif [ "$avail_mb" -lt "$DISK_WARN_MB" ]; then warn "$label ($mnt) : ${avail_mb} Mo libres (${pct} utilisé), sous ${DISK_WARN_MB} Mo."
    else ok "$label ($mnt) : ${avail_mb} Mo libres (${pct} utilisé)."; fi
    ipct=$(df -Pi "$path" 2>/dev/null | awk 'NR == 2 { gsub("%", "", $5); print $5 }')
    case "$ipct" in
        ''|*[!0-9]*) ;;
        *) [ "$ipct" -ge 98 ] && fail "$label ($mnt) : inodes saturés (${ipct} %)." || { [ "$ipct" -ge "$INODE_WARN_PCT" ] && warn "$label ($mnt) : inodes à ${ipct} %."; } ;;
    esac
}

sec_disk() {
    section "7. Stockage"
    load_docker
    disk_check "Dépôt" "$ROOT"
    if [ "$DOCKER_OK" -eq 1 ]; then
        droot=$($T docker info -f '{{.DockerRootDir}}' 2>/dev/null) || droot=""
        [ -n "$droot" ] && disk_check "Données Docker" "$droot"
    else
        disk_check "Données Docker" /var/lib/docker
    fi
    disk_check "/var/log" /var/log
    disk_check "/tmp" /tmp
    if [ "$DOCKER_OK" -eq 1 ]; then
        $T docker system df --format '{{.Type}} : {{.Size}} (récupérable {{.Reclaimable}})' 2>/dev/null \
            | while read -r l; do info "docker $l"; done
        if printf '%s\n' "$DOCKER_PS" | grep -q '^g2-suricata|'; then
            sz=$($T docker exec g2-suricata du -sh /var/log/suricata 2>/dev/null | awk '{print $1}') || sz=""
            [ -n "$sz" ] && info "Logs Suricata : $sz"
        fi
    fi
}

check_subnet_and_offload() {
    if have ip && have python3; then
        routes=$(ip -4 route show 2>/dev/null | awk '$1 ~ /\// { for (i = 2; i <= NF; i++) if ($i == "dev") print $1, $(i + 1) }' | grep -Ev ' (br-|docker0|veth)' || true)
        bad=$(printf '%s\n' "$routes" | python3 -I -c "$PY_OVERLAP" "$DMZ_SUBNET" 2>/dev/null || true)
        [ -n "$bad" ] && fail "Le sous-réseau DMZ $DMZ_SUBNET chevauche : $(printf '%s' "$bad" | tr '\n' ';')." || ok "Aucune route hôte ne chevauche $DMZ_SUBNET."
        if [ "$DOCKER_OK" -eq 1 ]; then
            nets=$($T docker network inspect -f '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}' $($T docker network ls -q 2>/dev/null) 2>/dev/null | awk '{ for (i = 2; i <= NF; i++) print $i, $1 }' | grep -Ev " ($LAB_NET_REGEX)" || true)
            badn=$(printf '%s\n' "$nets" | python3 -I -c "$PY_OVERLAP" "$DMZ_SUBNET" 2>/dev/null || true)
            [ -n "$badn" ] && fail "Un autre réseau Docker chevauche $DMZ_SUBNET : $(printf '%s' "$badn" | tr '\n' ';')." || ok "Aucun autre réseau Docker ne chevauche $DMZ_SUBNET."
        fi
    else
        warn "ip ou python3 absent : chevauchement DMZ non vérifié."
    fi

    if have ip; then
        br=$(ip -o -4 addr show 2>/dev/null | awk -v gw="$DMZ_GW" 'index($4, gw "/") == 1 { print $2; exit }')
        if [ -n "$br" ] && have ethtool; then
            off=$(ethtool -k "$br" 2>/dev/null | grep -E '^(generic-receive-offload|tcp-segmentation-offload|generic-segmentation-offload|large-receive-offload):' | grep ' on' | cut -d: -f1 | tr '\n' ' ')
            [ -n "$off" ] && warn "Offloading actif sur $br ($off) : sudo ethtool -K $br gro off lro off tso off gso off" || ok "Offloading désactivé sur $br."
        elif [ -n "$br" ]; then
            info "ethtool absent : offloading de $br non vérifié."
        else
            info "Bridge DMZ ($DMZ_GW) absent (démarrer le labo puis relancer)."
        fi
    fi
}

bilan() {
    label_ok="${1:-Poste client prêt}"
    label_warn="${2:-Poste client utilisable avec avertissements}"
    label_fail="${3:-Problèmes bloquants}"
    RULE="**********************************************************************"
    if [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then
        c="$BGREEN"; m="[OK] ${label_ok} (${PASS} OK, 0 WARN, 0 FAIL)."
    elif [ "$FAIL" -eq 0 ]; then
        c="$BYELLOW"; m="[WARN] ${label_warn} (${PASS} OK, ${WARN} WARN, 0 FAIL)."
    else
        c="$BRED"; m="[FAIL] ${label_fail} (${PASS} OK, ${WARN} WARN, ${FAIL} FAIL)."
    fi
    printf '\n%s%s%s\n  %s%s%s\n%s%s%s\n\n' "$c" "$RULE" "$RESET" "$c" "$m" "$RESET" "$c" "$RULE" "$RESET"
}
