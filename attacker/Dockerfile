# Conteneur attaquant du Groupe 2.
#
# Outils : nmap (scan SYN et detection de versions), curl (charges HTTP),
# dig (tunnel DNS) et sqlmap (injection SQL automatisee). Le conteneur vit sur
# le reseau DMZ comme n'importe quel poste externe.
#
# Il tourne en root parce que le scan SYN (nmap -sS) ouvre des sockets brutes :
# sans root ni capacite NET_RAW, nmap retombe sur une connexion complete, ce qui
# change la signature reseau observee par la sonde.
FROM alpine:3.20

RUN apk add --no-cache nmap nmap-nselibs nmap-scripts curl bind-tools ca-certificates \
    py3-pip py3-setuptools && \
    pip install --no-cache-dir --break-system-packages sqlmap

COPY scenario.sh /usr/local/bin/scenario.sh
RUN chmod 0755 /usr/local/bin/scenario.sh && \
    printf '%s\n' "export PS1='\\[\\033[31m\\]┌─[\\[\\033[1;31m\\]g2\\[\\033[0;2m\\]@\\[\\033[1;33m\\]attacker\\[\\033[0;31m\\]]─[\\[\\033[1;36m\\]\\w\\[\\033[0;31m\\]]\\n\\[\\033[1;31m\\]└──╼ #\\[\\033[0m\\] '" > /etc/shinit

ENV ENV=/etc/shinit
WORKDIR /scenario

ENTRYPOINT ["/usr/local/bin/scenario.sh"]
