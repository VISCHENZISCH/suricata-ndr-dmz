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
  <img src="https://img.shields.io/badge/FastAPI-API%20Interne-009688?style=for-the-badge&logo=fastapi&logoColor=white" alt="FastAPI">
  <img src="https://img.shields.io/badge/PostgreSQL-Cible%20DB-4169E1?style=for-the-badge&logo=postgresql&logoColor=white" alt="PostgreSQL">
</p>

<p align="center">
  <sub>IFRI - Université d'Abomey-Calavi · Licence 3 Sécurité Informatique · Outils de monitoring 2026-2027 · Groupe 2</sub>
</p>

---

## Aperçu

Ce projet déploie une zone DMZ simulée (`172.20.0.0/24`) composée d'un portail web Nginx, d'une API FastAPI interne et d'une base PostgreSQL, supervisée par **Suricata** et la console d'alertes **EveBox** (backend SQLite).

## Architecture

```
   ┌──────────────────────────────────────────────────────────────────┐
   │                    Réseau DMZ (172.20.0.0/24)                    │
   │                                                                  │
   │   web (172.20.0.10) ── /api/* ──▶ api (172.20.0.12) ──▶ db (.11) │
   │    Nginx :8082                    FastAPI (interne)    Postgres  │
   │                                                                  │
   │   evebox (172.20.0.14) ◀── volume suricata-logs (eve.json)       │
   │    Console :5636 (SQLite + auth)                                 │
   └──────────────────────────────────────────────────────────────────┘
```

## Démarrage rapide

```bash
git clone https://github.com/VISCHENZISCH/suricata-ndr-dmz.git && cd suricata-ndr-dmz
cp .env.example .env        # puis définir des mots de passe forts
docker compose up -d --build
```

**Prérequis :** Docker 24+, Docker Compose v2, environ 2 Go de RAM libres, Linux ou WSL2.

## Services déployés

| Service | Rôle | IP DMZ | Accès hôte |
|---|---|---|---|
| `web` | Portail Nginx + reverse proxy `/api/` | `172.20.0.10` | http://127.0.0.1:8082 |
| `db` | Base de données PostgreSQL 16 (`g2db`) | `172.20.0.11` | Réseau DMZ uniquement |
| `api` | API FastAPI (auth, sessions, santé DB) | `172.20.0.12` | Réseau DMZ uniquement |
| `evebox` | Console d'alertes EveBox (SQLite) | `172.20.0.14` | http://127.0.0.1:5636 |

Les identifiants (PostgreSQL et EveBox) sont définis dans `.env` : aucun compte par défaut n'est utilisé.

### Authentification du portail web (`web` + `api`)

- Inscription (`/register.html` → `POST /api/register`) et connexion (`/login.html` → `POST /api/login`) stockées dans PostgreSQL (`users`).
- Session gérée par cookie `HttpOnly` ; l'accès à `dashboard.html` est bloqué si non connecté et l'e-mail connecté s'affiche dans la barre de navigation.

### Console d'alertes (`evebox`)

- Backend **SQLite** léger avec rétention de 7 jours (`evebox/evebox.yaml`).
- Utilisateur créé automatiquement au premier démarrage via `evebox/entrypoint.sh` à partir de `EVEBOX_USER` et `EVEBOX_PASSWORD` (`.env`).

## Durcissement

- Aucun identifiant par défaut ; secrets gérés via `.env` (exclu de Git via `.gitignore`, modèle dans `.env.example`)
- Interfaces exposées uniquement sur `127.0.0.1` (`8082` pour `web`, `5636` pour `evebox`) ; `api` et `db` isolés dans la DMZ
- Images à version fixée (`nginx:1.27-alpine`, `postgres:16-alpine`, `python:3.12-slim`, `jasonish/evebox:0.32.0`)
- `no-new-privileges: true` sur tous les services, `read_only: true` sur `web` et `api`

## Structure du dépôt

```
├── docker-compose.yml       orchestration des services DMZ
├── .env.example             modèle des variables d'environnement
├── dmz/
│   ├── web/                 frontend HTML/CSS/JS + nginx.conf (reverse proxy)
│   ├── api/                 API FastAPI (Dockerfile, requirements.txt, app/main.py)
│   └── db/                  init.sql (schéma PostgreSQL)
├── evebox/                  evebox.yaml + entrypoint.sh (SQLite + auth)
├── suricata/                configuration, règles locales et mise à jour ET Open (à venir)
├── attacker/                conteneur attaquant et scenario.sh (à venir)
├── notifications/           alerting / Mailpit (à venir)
└── docs/                    cahier des charges, guide et ressources
```

## Feuille de route (en cours)

- [x] Zone DMZ applicative (`web`, `api`, `db`) avec reverse proxy et authentification
- [x] Console d'alertes `evebox` (SQLite, authentification depuis `.env`)
- [ ] Sonde NIDS `suricata` (`suricata.yaml`, règles custom `local.rules`, ET Open)
- [ ] Dashboards `Grafana` + `Loki` (Vue Direction & Vue Exploitation)
- [ ] Alerting et notifications (`Mailpit` / webhook)
- [ ] Conteneur `attacker` et scénario d'attaque (`scenario.sh`)

## Équipe

| Rôle | Membre |
|---|---|
| Architecte Déploiement, DevSecOps, IaC (chef d'équipe) | TOVIGNAN Kouassi Félix |
| Spécialiste Sécurisation & Durcissement | KPEGBE Uriel |
| Spécialiste Collecte, Ingestion & Sondes | AGBO Ognankitan Eliézer |
| Spécialiste Métrologie & Dashboards | AVOCETIEN Karol |
| Responsable Alerting & Notifications | DIMON Anaël |
| Spécialiste Détection & Scénarios d'Attaque | OKPEIFA Yves Dieudonné |

Enseignant : M. Abousidikou ODJO

## Avertissement

Projet à but pédagogique. Les attaques simulées ne doivent être exécutées que contre l'environnement isolé de ce dépôt, jamais contre des systèmes tiers.
