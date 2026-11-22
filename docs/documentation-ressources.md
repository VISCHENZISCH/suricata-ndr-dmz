# Documentation de référence - NDR DMZ (Suricata + EveBox)

## Suricata (détection)
- [Documentation officielle (guide utilisateur)](https://docs.suricata.io/en/latest/) : installation, configuration, `suricata.yaml`
- [Écriture des règles](https://docs.suricata.io/en/latest/rules/) : syntaxe, actions, options, `threshold`
- [Mots-clés HTTP](https://docs.suricata.io/en/latest/rules/http-keywords.html) : `http.uri`, `http.user_agent`, utiles pour les règles 1 et 2
- [Format de sortie Eve JSON](https://docs.suricata.io/en/latest/output/eve/eve-json-format.html) : structure d'`eve.json` (alertes, `stats`, `dns`, `http`)
- [Sortie Eve JSON (configuration)](https://docs.suricata.io/en/latest/output/eve/eve-json-output.html) : activer les types d'événements

## EveBox (console d'alertes)
- [Dépôt GitHub d'EveBox](https://github.com/jasonish/evebox) : point d'entrée principal, avec le lien vers la documentation
- [Documentation d'exécution du serveur](https://docs.rs/crate/evebox/latest/source/doc/server-running.rst) : lancement, entrée `eve.json`, authentification

## Règles ET Open et mise à jour
- [Emerging Threats (Proofpoint)](https://rules.emergingthreats.net/) : jeu de règles ET Open
- [Documentation de suricata-update](https://suricata-update.readthedocs.io/) : télécharger et activer les règles

## Docker, cibles et notifications
- [Docker Compose](https://docs.docker.com/compose/) : syntaxe du fichier, réseaux, volumes, `network_mode`
- [Référence du fichier Compose](https://docs.docker.com/reference/compose-file/) : `cap_add`, `read_only`, `security_opt`
- [Mailpit](https://mailpit.axllent.org/docs/) : serveur SMTP de test pour les notifications e-mail
- [Grafana Alerting](https://grafana.com/docs/grafana/latest/alerting/) : alerting et dashboards, si Grafana est conservé
- [Nginx](https://nginx.org/en/docs/) et [PostgreSQL](https://www.postgresql.org/docs/) : conteneurs cibles

## Outils de l'attaquant
- [Nmap](https://nmap.org/docs.html) : scans SYN (`-sS`) et de versions (`-sV`)
- [sqlmap](https://github.com/sqlmapproject/sqlmap/wiki/Usage) : options d'utilisation, pour le scénario d'injection SQL

## Conseils
- Pour les règles personnalisées, partir des mots-clés HTTP et tester avec `suricata -T -c suricata.yaml`.
- Pour l'image Docker de Suricata, partir de l'image officielle d'OISF ou de celle de Jason Ish (auteur d'EveBox), et vérifier leur page sur Docker Hub avant de fixer la version.

## Remarque
Les liens Suricata et EveBox ont été vérifiés par recherche. 