# Conteneur attaquant du Groupe 2.
#
# Volontairement minimal : nmap (scan SYN et detection de versions), curl
# (charges HTTP) et dig (tunnel DNS). Il n'embarque aucun outil qui ne serve au
# scenario, et il vit sur le reseau DMZ comme n'importe quel poste externe.
#
# Il tourne en root parce que le scan SYN (nmap -sS) ouvre des sockets brutes :
# sans root ni capacite NET_RAW, nmap retombe sur une connexion complete, ce qui
# change la signature reseau observee par la sonde.
FROM alpine:3.20

RUN apk add --no-cache nmap nmap-nselibs nmap-scripts curl bind-tools ca-certificates

COPY scenario.sh /usr/local/bin/scenario.sh
RUN chmod 0755 /usr/local/bin/scenario.sh

WORKDIR /scenario

ENTRYPOINT ["/usr/local/bin/scenario.sh"]
