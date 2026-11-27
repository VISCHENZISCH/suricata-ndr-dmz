#!/bin/sh
#Groupe 2 - Pré-vol poste client WSL / WSL2 (Windows)
#À exécuter depuis le terminal WSL :
#      ./scripts/check-wsl.sh [--fix] [--only LISTE] [--no-internet] [--strict]

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
# shellcheck source=scripts/lib-client.sh
. "$SCRIPT_DIR/lib-client.sh"

usage() {
    cat <<'EOF'
Usage : check-wsl.sh [options]

  --fix            resynchronise l'horloge WSL2 depuis Windows (hwclock -s / date -s)
  --only LISTE     sections : env,clock,net,docker,ports,tools,disk,host
  --no-internet    ignore les tests Internet / NTP
  --no-sudo        désactive sudo pour les contrôles privilégiés
  --strict         les WARN font échouer le code de sortie
  --no-banner      n'affiche pas l'en-tête
  -h, --help       affiche cette aide
EOF
}

parse_common_args "$@"
init_sudo

windows_offset() {
    have powershell.exe || return 1
    t0=$(date +%s)
    w=$($T powershell.exe -NoProfile -NonInteractive -Command '[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()' 2>/dev/null | tr -d '\r\n ') || true
    t1=$(date +%s)
    case "$w" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' $((w - (t0 + t1) / 2))
}

sec_env() {
    section "1. Environnement (WSL / Windows)"
    if grep -qi microsoft /proc/version 2>/dev/null; then
        if uname -r | grep -qi 'wsl2\|microsoft-standard' || [ -e /run/WSL ]; then
            ok "WSL2 détecté (noyau $(uname -r))."
            info "La VM WSL2 peut dériver après mise en veille de Windows."
        else
            warn "WSL1 détecté : Docker Engine / af-packet non supportés en WSL1, migrer vers WSL2."
        fi
    else
        warn "Ce script cible WSL, mais le noyau actuel semble être un Linux natif (utiliser ./scripts/check-linux.sh)."
    fi

    [ "$HAS_SYSTEMD" -eq 1 ] && ok "systemd actif (PID 1)." || warn "systemd inactif : ajouter [boot] systemd=true dans /etc/wsl.conf puis 'wsl --shutdown'."
    if [ -f /etc/wsl.conf ]; then
        info "/etc/wsl.conf présent."
        grep -Eqi '^[[:space:]]*generateResolvConf[[:space:]]*=[[:space:]]*false' /etc/wsl.conf \
            && info "generateResolvConf=false : /etc/resolv.conf géré manuellement."
    fi

    case "$ROOT" in
        /mnt/[a-zA-Z]/*) warn "Dépôt sur disque Windows ($ROOT) : lent et problèmes CRLF/permissions. Cloner dans ~/ (ext4 WSL)." ;;
        *)               ok "Dépôt sur ext4 WSL ($ROOT)." ;;
    esac
    check_common_env
}

sec_clock() {
    section "2. Horloge & synchronisation Windows/WSL"
    [ -n "$TMPD" ] && {
        have powershell.exe && ( o=$(windows_offset) && printf '%s' "$o" > "$TMPD/win" ) &
        if have curl; then
            ( o=$(http_offset "$LAB_URL") && printf '%s' "$o" > "$TMPD/lab" ) &
            if [ "$NO_INTERNET" -eq 0 ]; then
                ( for u in $TIME_URLS; do o=$(http_offset "$u") && { printf '%s %s' "$u" "$o" > "$TMPD/inet"; break; }; done ) &
            fi
        fi
        if [ "$NO_INTERNET" -eq 0 ] && have python3; then
            i=0; for s in $NTP_SERVERS; do i=$((i + 1)); ( o=$(sntp_offset "$s") && printf '%s %s' "$s" "$o" > "$TMPD/sntp.$i" ) & done
        fi
        wait
    }
    printf '  %s[INFO]%s Heure locale : %s | UTC : %s\n' "$DIM" "$RESET" "$(date '+%Y-%m-%d %H:%M:%S %Z (UTC%z)')" "$(date -u '+%H:%M:%S')"
    check_ntp_daemons
    { [ -e /dev/rtc0 ] || [ -e /dev/rtc ]; } && ok "RTC virtuelle présente (sudo hwclock -s disponible)." || info "Pas de /dev/rtc : utiliser date -s ou NTP."

    if [ -f "$TMPD/win" ]; then skew_check "hôte Windows" "$(cat "$TMPD/win")"
    else info "Interop powershell.exe indisponible : écart vs Windows non mesuré."; fi
    check_common_clock_refs
}

sec_host() {
    section "8. Hôte WSL2 (réseau, limites noyau, Docker Desktop)"
    load_docker
    check_subnet_and_offload

    ipf=$(read_sysctl net.ipv4.ip_forward)
    [ "$ipf" = "1" ] && ok "net.ipv4.ip_forward=1." || info "net.ipv4.ip_forward=${ipf:-?}."
    iw=$(to_int "$(read_sysctl fs.inotify.max_user_watches)")
    ii=$(to_int "$(read_sysctl fs.inotify.max_user_instances)")
    if { [ "$iw" -gt 0 ] && [ "$iw" -lt 8192 ]; } || { [ "$ii" -gt 0 ] && [ "$ii" -lt 128 ]; }; then
        warn "Limites inotify basses (watches=$iw, instances=$ii)."
    else
        ok "Limites inotify suffisantes (watches=$iw, instances=$ii)."
    fi
    [ -e /proc/net/packet ] && ok "af_packet disponible (capture Suricata)." || warn "/proc/net/packet absent : capture Suricata impossible."
}

fix_clock() {
    section "Correction de l'horloge WSL2 (--fix)"
    SU=""; [ "$(id -u)" -ne 0 ] && { have sudo && SU="sudo" || { fail "root ou sudo requis."; return; }; }
    if { [ -e /dev/rtc0 ] || [ -e /dev/rtc ]; } && have hwclock; then
        $SU hwclock -s >/dev/null 2>&1 && info "hwclock -s exécuté."
    fi
    BEST_OFFSET=""; BEST_SRC=""
    o=$(windows_offset) && { BEST_OFFSET="$o"; BEST_SRC="hôte Windows"; }
    if [ -z "$BEST_OFFSET" ] && [ "$NO_INTERNET" -eq 0 ]; then
        for s in $NTP_SERVERS; do o=$(sntp_offset "$s") && { BEST_OFFSET="$o"; BEST_SRC="NTP $s"; break; }; done
    fi
    [ -n "$BEST_OFFSET" ] || { fail "Aucune référence joignable."; return; }
    abs_le "$BEST_OFFSET" "$SKEW_WARN" && { ok "Horloge resynchronisée (écart ${BEST_OFFSET}s vs $BEST_SRC)."; return; }
    target=$(( $(date +%s) + $(round_int "$BEST_OFFSET") ))
    $SU date -u -s "@$target" >/dev/null 2>&1 && ok "Horloge recalée d'après $BEST_SRC." || fail "date -s refusé."
}

if [ -z "$NO_BANNER" ]; then
    printf '\n\n%s' "$ORANGE"
    cat <<'ART'
         888                        888                                      888 
         888                        888                                      888 
         888                        888                                      888 
 .d8888b 88888b.   .d88b.   .d8888b 888  888          888  888  888 .d8888b  888 
d88P"    888 "88b d8P  Y8b d88P"    888 .88P          888  888  888 88K      888 
888      888  888 88888888 888      888888K  888888   888  888  888 "Y8888b. 888 
Y88b.    888  888 Y8b.     Y88b.    888 "88b          Y88b 888 d88P      X88 888 
 "Y8888P 888  888  "Y8888   "Y8888P 888  888           "Y8888888P"   88888P' 888 
ART
    printf '%s  %sGroupe 2 · Pré-vol poste client WSL / WSL2%s\n\n\n' "$RESET" "$DIM" "$RESET"
fi

want env    && sec_env
want clock  && sec_clock
want net    && sec_net
want docker && sec_docker
want ports  && sec_ports
want tools  && sec_tools
want disk   && sec_disk
want host   && sec_host
[ "$FIX" -eq 1 ] && fix_clock
if want clock && { [ "$CLOCK_BAD" -eq 1 ] || [ "$NTP_DAEMON_OK" -eq 0 ]; }; then
    printf '\n%s--- Conseils horloge WSL2 ---%s\n  sudo hwclock -s   ou côté Windows : wsl --shutdown\n' "$BOLD" "$RESET"
fi

bilan
[ "$FAIL" -eq 0 ] || exit 1
[ "$STRICT" -eq 0 ] || [ "$WARN" -eq 0 ] || exit 1
exit 0
