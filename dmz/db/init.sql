
-- init.sql - Portail Suricata NDR / DMZ  (PostgreSQL)
-- Exécuté automatiquement lors de la première création du volume.


-- Table users : login.html + register.html
CREATE TABLE IF NOT EXISTS users (
    id            SERIAL       PRIMARY KEY,
    email         VARCHAR(254) NOT NULL UNIQUE,
    username      VARCHAR(50)  NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

