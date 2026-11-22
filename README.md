<h1 align="center">Suricata NDR - DMZ</h1>

<p align="center">
  Détection d'intrusions réseau (NIDS/NDR) avec <b>Suricata</b> et <b>EveBox</b>,<br>
  sur une zone DMZ simulée, déployable en une commande avec Docker Compose.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Suricata-NIDS-EF6C00?style=for-the-badge" alt="Suricata">
  <img src="https://img.shields.io/badge/EveBox-Alert%20Console-1E88E5?style=for-the-badge" alt="EveBox">
  <img src="https://img.shields.io/badge/Docker-Compose-2496ED?style=for-the-badge&logo=docker&logoColor=white" alt="Docker">
  <img src="https://img.shields.io/badge/Nginx-Cible%20Web-009639?style=for-the-badge&logo=nginx&logoColor=white" alt="Nginx">
  <img src="https://img.shields.io/badge/PostgreSQL-Cible%20DB-4169E1?style=for-the-badge&logo=postgresql&logoColor=white" alt="PostgreSQL">
  <img src="https://img.shields.io/badge/Grafana-Dashboards-F46800?style=for-the-badge&logo=grafana&logoColor=white" alt="Grafana">
</p>

<p align="center">
  <sub>IFRI - Université d'Abomey-Calavi · Licence 3 Sécurité Informatique · Outils de monitoring 2026-2027 · Groupe 2</sub>
</p>

---

## Aperçu

Ce projet déploie un NIDS **Suricata** qui inspecte en temps réel le trafic d'une DMZ simulée (serveur web + base de données). Les alertes sont centralisées, classées par sévérité et acquittées dans **EveBox**. Un conteneur attaquant rejoue un scénario d'attaque réaliste pour prouver la détection en direct.

## Architecture

```
                 ┌────────────┐
                 │  attacker  │  nmap · sqlmap · dig
                 └─────┬──────┘
                       │  réseau DMZ (172.20.0.0/24)
        ┌──────────────┼───────────────┐
        │              │               │
        ▼              ▼               ▼
       web             db           suricata  ── eve.json ──┐
     (nginx)        (postgres)       (NIDS)                 │
                                                            ▼
                             ┌─────────┐   ┌──────────┐  ┌─────────┐
                               Mailpit  ◄──  alerting  ◄─  EveBox  
                             └─────────┘   └──────────┘  └─────────┘
```

Suricata partage l'espace réseau du serveur web pour observer tout le trafic qui lui est destiné.

## Démarrage rapide

```bash
git clone https://github.com/VISCHENZISCH/suricata-ndr-dmz.git && cd suricata-ndr-dmz
cp .env.example .env        # puis définir des mots de passe forts
docker compose up -d
```

**Prérequis :** Docker 24+, Docker Compose v2, environ 2 Go de RAM libres, Linux ou WSL2.

## Services

| Service | Rôle | Accès |
|---|---|---|
| EveBox | Console d'alertes | http://127.0.0.1:5636 |
| Grafana | Dashboards Direction / Exploitation | http://127.0.0.1:3000 |
| Mailpit | Réception des notifications e-mail | http://127.0.0.1:8025 |
| web / db | Infrastructure cible supervisée | Réseau DMZ uniquement |
| attacker | Génération des attaques | `docker compose exec attacker bash` |

Les identifiants sont définis dans `.env` : aucun compte par défaut n'est utilisé.

## Règles de détection

- **ET Open** : jeu de règles communautaire Emerging Threats, mis à jour via `suricata/update-rules.sh`.
- **Règles personnalisées** (`suricata/rules/local.rules`) :

| SID | Détection |
|---|---|
| 1000001 | Injection SQL (`UNION SELECT`) dans une requête HTTP |
| 1000002 | User-Agent d'outil d'attaque (`sqlmap`) |
| 1000003 | Volume anormal de requêtes DNS (tunnel DNS) |

Validation de la configuration : `docker compose exec suricata suricata -T -c /etc/suricata/suricata.yaml`

## Épreuve du feu

```bash
docker compose exec attacker ./scenario.sh
```

Le scénario enchaîne :

1. Scan de ports Nmap (SYN, détection de versions)
2. Injection SQL et traversée de répertoires contre le serveur web
3. Tentative d'exfiltration par tunnel DNS

Les alertes apparaissent aussitôt dans EveBox et déclenchent une notification Mailpit.

## Durcissement

- Aucun identifiant par défaut, secrets gérés via `.env` (jamais versionné)
- Interfaces d'administration exposées sur `127.0.0.1` uniquement
- Authentification activée sur EveBox et Grafana
- Images à version fixée, `no-new-privileges`, capabilities réduites au strict nécessaire
- Configurations, règles et dashboards persistés et versionnés (Monitoring as Code)

## Structure du dépôt

```
├── docker-compose.yml
├── .env.example
├── suricata/        configuration, règles, mise à jour ET Open
├── evebox/          configuration et création de l'utilisateur
├── dmz/             cibles supervisées (web, db)
├── attacker/        image attaquant et scenario.sh
├── notifications/   Mailpit / webhook
└── docs/            schémas, captures, rapport, documentations
```

## Équipe

| Rôle | Membre |
|---|---|
| Architecte Déploiement, DevSecOps, IaC (chef d'équipe) | TOVIGNAN Kouassi Félix|
| Spécialiste Sécurisation & Durcissement | _______________  |
| Spécialiste Collecte, Ingestion & Sondes | _______________ |
| Spécialiste Métrologie & Dashboards |_______________ |
| Responsable Alerting & Notifications | _______________  |
| Spécialiste Détection & Scénarios d'Attaque | _______________  |

Enseignant : M. Abousidikou ODJO

## Avertissement

Projet à but pédagogique. Les attaques simulées ne doivent être exécutées que contre l'environnement isolé de ce dépôt, jamais contre des systèmes tiers.
