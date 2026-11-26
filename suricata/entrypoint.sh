#!/bin/sh
# Point d'entree de la sonde NDR du Groupe 2.
# Le conteneur partage la pile reseau de l'hote (network_mode: host) : il doit
# donc retrouver lui-meme le bridge Docker de la DMZ, dont le nom (br-xxxx)
# depend d'un identifiant genere par Docker Compose et change d'une machine a
# l'autre. On le localise par l'adresse de passerelle du reseau.
set -eu

BCYAN=$(printf '\033[1;96m')
BGREEN=$(printf '\033[1;92m')
BRED=$(printf '\033[1;91m')
DIM=$(printf '\033[2m')
RESET=$(printf '\033[0m')

printf '\n\n%s' "$BCYAN"
cat <<'ART'
                  888                                       d8b          888    
                  888                                       Y8P          888    
                  888                                                    888    
 .d88b.  88888b.  888888 888d888 888  888 88888b.   .d88b.  888 88888b.  888888 
d8P  Y8b 888 "88b 888    888P"   888  888 888 "88b d88""88b 888 888 "88b 888    
88888888 888  888 888    888     888  888 888  888 888  888 888 888  888 888    
Y8b.     888  888 Y88b.  888     Y88b 888 888 d88P Y88..88P 888 888  888 Y88b.  
 "Y8888  888  888  "Y888 888      "Y88888 88888P"   "Y88P"  888 888  888  "Y888 
                                      888 888                                   
                                 Y8b d88P 888                                   
                                  "Y88P"  888                                   
ART
printf '%s  %sGroupe 2 · Sonde NDR Suricata (af-packet DMZ)%s\n\n\n' "$RESET" "$DIM" "$RESET"


DMZ_GATEWAY="${DMZ_GATEWAY:-172.20.0.1}"
IFACE="${SURICATA_IFACE:-}"

if [ -z "$IFACE" ]; then
    IFACE=$(ip -o -4 addr show |
        awk -v prefix="${DMZ_GATEWAY}/" 'index($4, prefix) == 1 { print $2; exit }')
fi

if [ -z "$IFACE" ]; then
    printf '%s[suricata] Aucune interface ne porte %s.%s\n' "$BRED" "$DMZ_GATEWAY" "$RESET" >&2
    printf '%s[suricata] Le reseau DMZ est-il demarre (docker compose up -d) ?%s\n' "$BRED" "$RESET" >&2
    exit 1
fi

printf '%s[suricata] Capture af-packet sur l interface %s (reseau %s/24)%s\n' "$BGREEN" "$IFACE" "$DMZ_GATEWAY" "$RESET"

mkdir -p /var/log/suricata /var/run/suricata /var/lib/suricata/rules

# Le jeu ET Open est telecharge par suricata/update-rules.sh. Suricata refuse
# de demarrer si un fichier de regles declare est absent : on garantit donc sa
# presence, quitte a le laisser vide au tout premier demarrage.
[ -f /var/lib/suricata/rules/suricata.rules ] ||
    : > /var/lib/suricata/rules/suricata.rules

# Un arret brutal laisse le fichier de PID derriere lui et Suricata refuse
# alors de redemarrer ("pid file exists and Suricata appears to be running").
rm -f /var/run/suricata/suricata.pid

# Suricata ouvre la capture en root puis abandonne ses privileges : le compte
# suricata doit pouvoir ecrire les journaux et le socket de commande.
chown -R suricata:suricata /var/log/suricata /var/run/suricata 2>/dev/null || true

# Une interface de bridge ne remonte une copie des trames commutees entre deux
# ports que si elle est en mode promiscuous : le noyau clone alors chaque trame
# vers la pile locale, ou af-packet la recupere. Suricata n'active pas ce mode
# de lui-meme en af-packet, et sans lui la sonde ne verrait que le multicast
# (mDNS, SSDP) adresse au bridge, jamais le trafic entre conteneurs.
# C'est cette operation qui justifie la capacite NET_ADMIN.
if ! ip link set dev "$IFACE" promisc on; then
    echo "[suricata] Impossible de passer ${IFACE} en mode promiscuous." >&2
    exit 1
fi

cleanup() {
    ip link set dev "$IFACE" promisc off 2>/dev/null || true
}

suricata \
    -c /etc/suricata/suricata.yaml \
    -i "$IFACE" \
    --user suricata \
    --group suricata \
    --pidfile /var/run/suricata/suricata.pid &
suricata_pid=$!

trap 'kill -TERM "$suricata_pid" 2>/dev/null || true' INT TERM

rc=0
wait "$suricata_pid" || rc=$?

cleanup
exit "$rc"
