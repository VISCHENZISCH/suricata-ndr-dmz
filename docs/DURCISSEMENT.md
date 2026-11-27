# Durcissement de la pile — Groupe 2

Pilier 2 du cahier des charges (3 points). Ce document recense chaque mesure, sa
mise en œuvre et la commande qui la prouve. Toutes les preuves ci-dessous ont été
exécutées sur la pile en fonctionnement.

## Synthèse

| Exigence | État | Où |
|---|---|---|
| Aucun identifiant par défaut | OK | `.env.example`, `evebox/entrypoint.sh`, `docker-compose.yml` |
| Secrets hors du dépôt | OK | `.env` en `600`, exclu par `.gitignore` |
| Ports limités à `127.0.0.1` | OK | 4 ports publiés, tous sur la boucle locale |
| Authentification EveBox | OK | `authentication.required: true` |
| Authentification Grafana | OK | admin via `.env`, anonyme et inscription désactivés |
| Versions d'images figées | OK | 8 images, aucun `:latest` |
| `no-new-privileges` | OK | 9 conteneurs sur 9 |
| Racine en lecture seule | OK | 9 conteneurs sur 9, `tmpfs` ciblés |
| Capabilities minimales | OK | `cap_drop: ALL` partout, `cap_add` justifié service par service |
| Journalisation bornée | OK | `json-file`, 10 Mo × 3 par service |

## 1. Identités et authentification

**Aucun compte par défaut.** Les trois identités de la pile sont créées à partir
de `.env` au premier démarrage, jamais codées en dur :

| Service | Compte | Mécanisme |
|---|---|---|
| EveBox | `EVEBOX_USER` | `evebox/entrypoint.sh` crée l'utilisateur dans SQLite s'il n'existe pas |
| Grafana | `GRAFANA_ADMIN_USER` | `GF_SECURITY_ADMIN_USER` / `GF_SECURITY_ADMIN_PASSWORD` |
| PostgreSQL | `g2user` | `POSTGRES_USER` / `POSTGRES_PASSWORD`, SCRAM-SHA-256 |

**EveBox** exige une session pour toute lecture de données :

```console
$ curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:5636/api/alerts
401
```

La page d'accueil répond 200 : c'est la coquille statique de l'application, les
données restent derrière `/api/*`, protégées par l'authentification.

**Grafana** : accès anonyme et inscription désactivés, API fermée sans session :

```console
$ curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3001/api/dashboards/home
401
$ curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3001/dashboard
302   # redirection vers /login
```

**PostgreSQL** : les lignes `trust` générées par `initdb` (socket Unix et
`127.0.0.1`) ont été supprimées par `dmz/db/harden-hba.sh`, exécuté une fois à
l'initialisation du volume. Toute connexion, locale ou réseau, exige désormais
le mot de passe :

```console
$ docker exec g2-db psql -U g2user -d g2db -c 'select 1'
psql: error: ... fe_sendauth: no password supplied
```

## 2. Secrets

- `.env` n'est jamais versionné (`.gitignore`), un modèle `.env.example` est fourni.
- Permissions `600` : lisible par le seul propriétaire.
- Les mots de passe sont générés aléatoirement (`python3 -c 'secrets.token_urlsafe(24)'`),
  pas choisis à la main.

```console
$ stat -c '%a %n' .env
600 .env
$ git ls-files --error-unmatch .env
Did you forget to 'git add'?
```

À noter pour le rapport : les secrets passent par des variables d'environnement,
donc restent visibles dans `docker inspect`. La suite logique serait les secrets
Docker (`POSTGRES_PASSWORD_FILE`, `GF_SECURITY_ADMIN_PASSWORD__FILE`), hors
périmètre de cette séance.

## 3. Exposition réseau

Seuls quatre ports sortent du réseau Docker, tous sur la boucle locale :

| Port hôte | Service | Usage |
|---|---|---|
| `127.0.0.1:8082` | web | portail |
| `127.0.0.1:5636` | evebox | console d'alertes |
| `127.0.0.1:3001` | grafana | dashboards (3000 occupé sur cette machine, voir `docker-compose.override.yml`) |
| `127.0.0.1:8025` | mailpit | boîte de réception des alertes |

`api` (8000), `db` (5432), `loki` (3100) et `promtail` (9080) ne sont joignables
que depuis les réseaux Docker `dmz` et `monitoring`.

```console
$ docker compose ps --format '{{.Ports}}' | grep -Eo '(0\.0\.0\.0|\[::\]):[0-9]+'
(aucune sortie)
```

## 4. Durcissement des conteneurs

### Racine en lecture seule

Les 9 conteneurs tournent avec `read_only: true`. Seuls les volumes nommés et
quelques `tmpfs` ciblés sont inscriptibles :

| Service | Écritures autorisées |
|---|---|
| web | `tmpfs` `/var/cache/nginx`, `/var/run`, `/tmp` |
| api | `tmpfs` `/tmp` |
| db | volume `db-data`, `tmpfs` `/var/run/postgresql`, `/tmp` |
| evebox | volumes `evebox-data`, `suricata-logs` (ro), `tmpfs` `/tmp` |
| suricata | volumes `suricata-logs`, `suricata-rules`, `tmpfs` `/var/run/suricata` |
| loki / promtail | volumes `loki-data`, `promtail-pos`, `tmpfs` `/tmp` |
| grafana | volume `grafana-data`, `tmpfs` `/tmp` |
| mailpit | `tmpfs` `/tmp` (stockage en mémoire) |
| attacker | `tmpfs` `/tmp`, `/root` |

### Capabilities minimales

`cap_drop: [ALL]` est appliqué partout ; les capacités sont rendues au cas par
cas, et chaque ajout est commenté dans le `docker-compose.yml`.

| Service | Capabilities rendues | Justification |
|---|---|---|
| api, evebox, mailpit, grafana, loki, promtail, attacker | aucune (attacker : `NET_RAW`) | inutiles |
| web | `NET_BIND_SERVICE`, `CHOWN`, `DAC_OVERRIDE`, `SETGID`, `SETUID` | se lier au port 80, écrire pid/cache, passer au compte nginx |
| db | `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETGID`, `SETUID` | `chown` du volume puis abandon vers le compte postgres |
| suricata | `NET_ADMIN`, `NET_RAW`, `SYS_NICE`, `CHOWN`, `DAC_OVERRIDE`, `SETUID`, `SETGID`, `SETPCAP` | promiscuité du bridge, capture af-packet, ordonnancement, puis abandon de privilèges vers le compte suricata |

```console
$ docker inspect g2-suricata --format '{{.HostConfig.CapDrop}} {{.HostConfig.CapAdd}}'
[ALL] [CAP_NET_ADMIN CAP_NET_RAW CAP_SYS_NICE CAP_CHOWN CAP_DAC_OVERRIDE CAP_SETUID CAP_SETGID CAP_SETPCAP]
```

### Autres mesures

- `no-new-privileges: true` sur les 9 conteneurs : aucun binaire `setuid` ne peut
  élever ses privilèges à l'intérieur d'un conteneur.
- Comptes non-root : `apiuser` (10001) pour l'API, `472` pour Grafana, `10001`
  pour Loki ; PostgreSQL et Suricata démarrent en root puis **abandonnent** leurs
  privilèges (`--user suricata --group suricata`, `su-exec postgres`).
- Journalisation bornée : `json-file` avec `max-size: 10m` et `max-file: 3`
  (30 Mo par service). Sans plafond, un conteneur bavard remplit le disque de
  l'hôte et fait tomber la pile, sonde comprise.
- Healthchecks sur les 9 services, avec `start_period` adapté : 180 s pour
  Suricata, qui charge 53 000 signatures avant d'être réellement prêt.

## 5. Images

Huit images, toutes épinglées, aucune en `:latest` :

```
nginx:1.27-alpine      postgres:16-alpine     jasonish/evebox:0.32.0
grafana/loki:3.2.0     grafana/promtail:3.2.0 grafana/grafana:11.3.0
axllent/mailpit:v1.21  jasonish/suricata:7.0.17 (base de g2/suricata-ndr:7.0.17)
```

## 6. Risques acceptés

| Risque | Justification | Piste |
|---|---|---|
| Mailpit sans authentification | outil de démonstration, publié sur `127.0.0.1` uniquement | authentification de l'UI Mailpit |
| Secrets en variables d'environnement | visibles via `docker inspect`, hôte mono-utilisateur | secrets Docker + `_FILE` |
| EveBox, Mailpit et Promtail en root dans le conteneur | images amont qui n'embarquent pas d'utilisateur dédié | `user:` dédié, à valider sur les volumes |
| Pas de TLS | trafic local, ports sur la boucle locale | reverse proxy TLS pour la démonstration distante |
| Sessions API en mémoire | perdues au redémarrage, mono-instance | sessions en base |

## 7. Vérification en une commande

```bash
./scripts/check-lab.sh
```

La section 7 du script contrôle automatiquement : lecture seule, `no-new-privileges`,
`cap_drop`, ports hors boucle locale, tags `:latest`, permissions de `.env`,
versionnement de `.env`, et l'authentification d'EveBox et de Grafana.

```console
==> 7. Durcissement (racine en lecture seule, capabilities, exposition)
  [OK]   Racine en lecture seule sur les 9 services.
  [OK]   no-new-privileges actif partout.
  [OK]   cap_drop ALL par defaut, capabilities rendues au cas par cas.
  [OK]   Aucun port publié hors de la boucle locale (127.0.0.1).
  [OK]   Images épinglées (aucun tag :latest).
  [OK]   .env lisible par son seul propriétaire (600).
  [OK]   .env exclu de Git (.gitignore).
  [OK]   EveBox impose une authentification (401 sans identifiants).
  [OK]   Grafana impose une authentification (401 sans identifiants).
```
