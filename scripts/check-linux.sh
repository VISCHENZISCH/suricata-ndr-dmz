#!/bin/sh
#Groupe 2 - Pré-vol poste client Linux natif / VM (Parrot, Kali, Debian, Ubuntu)
#À exécuter depuis n'importe où :
#      ./scripts/check-linux.sh [--fix] [--only LISTE] [--no-internet] [--strict]

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
# shellcheck source=scripts/lib-client.sh
. "$SCRIPT_DIR/lib-client.sh"

usage() {
    cat <<'EOF'
Usage : check-linux.sh [options]

  --fix            resynchronise l'horloge (chrony/date -s, sudo requis)
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

sec_env() {
    section "1. Environnement (Linux natif / VM)"
    if [ -r /etc/os-release ]; then
        os_id=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
        os_name=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"')
        case "$os_id" in
            kali|parrot|debian|ubuntu) ok "Système : $os_name." ;;
            *) warn "Système : ${os_name:-inconnu}." ;;
        esac
    fi
    ok "Noyau Linux : $(uname -r)."
    [ "$HAS_SYSTEMD" -eq 1 ] && ok "systemd actif (PID 1)." || info "systemd inactif."
    check_common_env
    ok "Dépôt sur système de fichiers Linux ($ROOT)."
}

sec_clock() {
    section "2. Horloge & NTP (Linux)"
    [ -n "$TMPD" ] && {
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
    tz_name=$(cat /etc/timezone 2>/dev/null || readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')
    [ -n "$tz_name" ] && ok "Fuseau horaire : $tz_name." || warn "Fuseau horaire non déterminé (sudo dpkg-reconfigure tzdata)."

    check_ntp_daemons

    localrtc=$(timedatectl show -p LocalRTC --value 2>/dev/null || true)
    [ -z "$localrtc" ] && [ "$(tail -n 1 /etc/adjtime 2>/dev/null)" = "LOCAL" ] && localrtc=yes
    dual=0
    priv ls /boot/efi/EFI 2>/dev/null | grep -qi microsoft && dual=1
    [ -d /boot/efi/EFI/Microsoft ] && dual=1
    if [ "$localrtc" = "yes" ]; then
        warn "RTC en heure locale (LocalRTC=yes) : préférer UTC (sudo timedatectl set-local-rtc 0)."
    elif [ "$dual" -eq 1 ]; then
        warn "Dual-boot Windows détecté (RTC UTC) : activer RealTimeIsUniversal côté Windows si décalage."
    fi

    check_common_clock_refs
}

sec_host() {
    section "8. Hôte Linux (réseau, pare-feu, noyau, sécurité)"
    load_docker
    check_subnet_and_offload

    if [ "$HAS_SYSTEMD" -eq 1 ] && have systemctl; then
        systemctl is-active --quiet ufw 2>/dev/null && warn "ufw actif : vérifier DEFAULT_FORWARD_POLICY=\"ACCEPT\" (/etc/default/ufw)."
        systemctl is-active --quiet firewalld 2>/dev/null && warn "firewalld actif : vérifier firewall-cmd --get-active-zones."
        if systemctl is-active --quiet NetworkManager 2>/dev/null && have nmcli; then
            nm=$(nmcli -t -f DEVICE,STATE device 2>/dev/null | grep -E '^(br-|docker0)' | grep -v ':unmanaged' || true)
            [ -n "$nm" ] && warn "NetworkManager gère des bridges Docker : risque de perte du mode promiscuous." || ok "NetworkManager ne gère pas les bridges Docker."
        fi
    fi

    ipf=$(read_sysctl net.ipv4.ip_forward)
    [ "$ipf" = "1" ] && ok "net.ipv4.ip_forward=1." || { [ "$DOCKER_OK" -eq 1 ] && fail "net.ipv4.ip_forward=${ipf:-?} (sudo sysctl -w net.ipv4.ip_forward=1)." || info "net.ipv4.ip_forward=${ipf:-?}."; }
    [ "$(read_sysctl net.ipv4.conf.all.rp_filter)" = "1" ] && info "rp_filter=1 (passer à 2 si du trafic asymétrique est filtré)."

    iw=$(to_int "$(read_sysctl fs.inotify.max_user_watches)")
    ii=$(to_int "$(read_sysctl fs.inotify.max_user_instances)")
    if { [ "$iw" -gt 0 ] && [ "$iw" -lt 8192 ]; } || { [ "$ii" -gt 0 ] && [ "$ii" -lt 128 ]; }; then
        warn "Limites inotify basses (watches=$iw, instances=$ii) : risque pour Promtail/Loki."
    else
        ok "Limites inotify suffisantes (watches=$iw, instances=$ii)."
    fi

    { [ -d /proc/sys/net/bridge ] || { have lsmod && lsmod 2>/dev/null | grep -q '^br_netfilter'; }; } && ok "br_netfilter chargé." || warn "br_netfilter absent (sudo modprobe br_netfilter)."
    { [ -e /proc/net/packet ] || { have lsmod && lsmod 2>/dev/null | grep -q '^af_packet'; }; } && ok "af_packet disponible (capture Suricata)." || warn "af_packet introuvable."

    if have getenforce && [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then
        printf '%s\n' "$COMPOSE_CFG" | grep -Eq ':(z|Z)(,|$| )' && ok "SELinux Enforcing avec :z/:Z." || warn "SELinux Enforcing sans :z/:Z sur les volumes."
    elif [ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)" = "Y" ]; then
        info "AppArmor actif (profil docker-default)."
    fi

    if have VBoxManage; then
        { [ -e /dev/vboxdrv ] || { have lsmod && lsmod 2>/dev/null | grep -q '^vboxdrv'; }; } && ok "VirtualBox : vboxdrv chargé." || warn "VirtualBox installé sans module vboxdrv."
    fi
}

fix_clock() {
    section "Correction de l'horloge (--fix)"
    SU=""; [ "$(id -u)" -ne 0 ] && { have sudo && SU="sudo" || { fail "root ou sudo requis."; return; }; }
    BEST_OFFSET=""; BEST_SRC=""
    if [ "$NO_INTERNET" -eq 0 ]; then
        for s in $NTP_SERVERS; do o=$(sntp_offset "$s") && { BEST_OFFSET="$o"; BEST_SRC="NTP $s"; break; }; done
    fi
    [ -z "$BEST_OFFSET" ] && o=$(http_offset "$LAB_URL") && { BEST_OFFSET="$o"; BEST_SRC="labo"; }
    [ -n "$BEST_OFFSET" ] || { fail "Aucune référence joignable."; return; }
    abs_le "$BEST_OFFSET" "$SKEW_WARN" && { ok "Horloge déjà correcte (écart ${BEST_OFFSET}s)."; return; }
    target=$(( $(date +%s) + $(round_int "$BEST_OFFSET") ))
    $SU date -u -s "@$target" >/dev/null 2>&1 && ok "Horloge recalée d'après $BEST_SRC." || fail "date -s refusé."
}

if [ -z "$NO_BANNER" ]; then
    printf '\n\n%s' "$ORANGE"
    cat <<'ART'
         888                        888               888 d8b                            
         888                        888               888 Y8P                            
         888                        888               888                                
 .d8888b 88888b.   .d88b.   .d8888b 888  888          888 888 88888b.  888  888 888  888 
d88P"    888 "88b d8P  Y8b d88P"    888 .88P          888 888 888 "88b 888  888 `Y8bd8P' 
888      888  888 88888888 888      888888K  888888   888 888 888  888 888  888   X88K   
Y88b.    888  888 Y8b.     Y88b.    888 "88b          888 888 888  888 Y88b 888 .d8""8b. 
 "Y8888P 888  888  "Y8888   "Y8888P 888  888          888 888 888  888  "Y88888 888  888 
ART
    printf '%s  %sGroupe 2 · Pré-vol poste client Linux natif / VM%s\n\n\n' "$RESET" "$DIM" "$RESET"
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
    printf '\n%s--- Conseils horloge Linux ---%s\n  sudo apt install chrony && sudo systemctl enable --now chrony\n' "$BOLD" "$RESET"
fi

bilan
[ "$FAIL" -eq 0 ] || exit 1
[ "$STRICT" -eq 0 ] || [ "$WARN" -eq 0 ] || exit 1
exit 0
