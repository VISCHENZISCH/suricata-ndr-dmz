#!/bin/sh
# Durcissement de l'authentification PostgreSQL (Groupe 2).
#
# initdb ecrit par defaut des lignes "trust" pour le socket Unix et pour
# 127.0.0.1 : n'importe quel processus du conteneur pourrait alors se connecter
# sans mot de passe. L'entrypoint officiel ajoute bien une ligne scram-sha-256
# pour les connexions reseau, mais laisse le local en trust.
#
# Ce script remplace entierement pg_hba.conf : toute connexion, locale ou
# distante, exige desormais le mot de passe defini dans .env (scram-sha-256).
# Il est execute une seule fois, a l'initialisation du volume de donnees.
set -eu

cat > "${PGDATA}/pg_hba.conf" <<'EOF'
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             all                                     scram-sha-256
host    all             all             0.0.0.0/0               scram-sha-256
host    all             all             ::/0                    scram-sha-256
EOF

echo "[db] pg_hba.conf durci : authentification scram-sha-256 obligatoire (local et reseau)."
