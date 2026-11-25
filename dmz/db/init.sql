
-- init.sql  –  Portail Suricata NDR / DMZ  (PostgreSQL)
-- Exécuté automatiquement lors de la première création du volume.


-- Table users : login.html + register.html
CREATE TABLE IF NOT EXISTS users (
    id            SERIAL       PRIMARY KEY,
    email         VARCHAR(254) NOT NULL UNIQUE,
    username      VARCHAR(50)  NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    role          VARCHAR(20)  NOT NULL DEFAULT 'user'
                  CHECK (role IN ('admin', 'operator', 'analyst', 'user')),
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Compte admin initial (hash bcrypt à remplacer avant la prod)
INSERT INTO users (email, username, password_hash, role)
VALUES ('admin@ndr-dmz.local', 'admin', '$2b$12$CHANGEME_HASH_ADMIN', 'admin')
ON CONFLICT (email) DO NOTHING;
