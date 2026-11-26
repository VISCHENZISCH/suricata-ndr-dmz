#!/bin/sh
# Point d'entree de la sonde NDR du Groupe 2.
# Le conteneur partage la pile reseau de l'hote (network_mode: host) : il doit
# donc retrouver lui-meme le bridge Docker de la DMZ, dont le nom (br-xxxx)
# depend d'un identifiant genere par Docker Compose et change d'une machine a
# l'autre. On le localise par l'adresse de passerelle du reseau.
set -eu

DMZ_GATEWAY="${DMZ_GATEWAY:-172.20.0.1}"
IFACE="${SURICATA_IFACE:-}"

if [ -z "$IFACE" ]; then
    IFACE=$(ip -o -4 addr show |
        awk -v prefix="${DMZ_GATEWAY}/" 'index($4, prefix) == 1 { print $2; exit }')
fi

if [ -z "$IFACE" ]; then
    echo "[suricata] Aucune interface ne porte ${DMZ_GATEWAY}." >&2
    echo "[suricata] Le reseau DMZ est-il demarre (docker compose up -d) ?" >&2
    exit 1
fi

echo "[suricata] Capture af-packet sur l'interface ${IFACE} (reseau ${DMZ_GATEWAY}/24)"

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
