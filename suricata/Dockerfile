# Sonde Suricata du Groupe 2.
# L'image officielle jasonish/suricata (AlmaLinux 9) fournit la sonde,
# suricata-update, suricatasc et iproute2. On remplace son point d'entree par
# le notre, qui localise le bridge Docker de la DMZ avant de lancer Suricata.
FROM jasonish/suricata:7.0.17

# Root requis au demarrage pour passer br-xxxx en promiscuous et chown les volumes ;
# Suricata abandonne ensuite ses privileges via --user suricata --group suricata.
# hadolint ignore=DL3002
USER root

COPY entrypoint.sh /usr/local/bin/ndr-entrypoint.sh
RUN chmod 0755 /usr/local/bin/ndr-entrypoint.sh

HEALTHCHECK --interval=20s --timeout=5s --start-period=20s --retries=3 \
    CMD suricatasc -c uptime || exit 1

ENTRYPOINT ["/usr/local/bin/ndr-entrypoint.sh"]
