CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    username VARCHAR(50) NOT NULL,
    role VARCHAR(20) NOT NULL
);

INSERT INTO
    users (username, role)
VALUES ('alice', 'admin'),
    ('bob', 'user'),
    ('carol', 'user');