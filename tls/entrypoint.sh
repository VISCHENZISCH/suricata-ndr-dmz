#!/bin/sh
set -eu

CERTS_DIR="/certs"
WORK_DIR="/tmp/tls-work"
CA_DAYS=3650
LEAF_DAYS=825

mkdir -p "$CERTS_DIR" "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

fix_perms() {
    chown 0:0 "$CERTS_DIR/ca.crt" "$CERTS_DIR/ca.key" "$CERTS_DIR/evebox.crt" "$CERTS_DIR/evebox.key"
    chmod 644 "$CERTS_DIR/ca.crt" "$CERTS_DIR/evebox.crt"
    chmod 600 "$CERTS_DIR/ca.key" "$CERTS_DIR/evebox.key"

    # Grafana (grafana/grafana:11.3.0) tourne sous l'UID/GID 472
    chmod 644 "$CERTS_DIR/grafana.crt"
    chmod 600 "$CERTS_DIR/grafana.key"
    chown 472:472 "$CERTS_DIR/grafana.crt" "$CERTS_DIR/grafana.key"
}

certs_valid() {
    for f in ca.crt ca.key evebox.crt evebox.key grafana.crt grafana.key; do
        [ -s "$CERTS_DIR/$f" ] || return 1
    done
    openssl verify -CAfile "$CERTS_DIR/ca.crt" "$CERTS_DIR/evebox.crt" >/dev/null 2>&1 || return 1
    openssl verify -CAfile "$CERTS_DIR/ca.crt" "$CERTS_DIR/grafana.crt" >/dev/null 2>&1 || return 1
}

issue_cert() {
    name="$1"
    cn="$2"
    san="$3"

    cat > "$WORK_DIR/${name}.cnf" <<EOF
[req]
prompt = no
distinguished_name = dn
req_extensions = v3_req

[dn]
O = Suricata-NDR-DMZ
OU = Groupe 2
CN = ${cn}

[v3_req]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = ${san}
EOF

    openssl req -new -nodes -newkey rsa:2048 \
        -keyout "$CERTS_DIR/${name}.key" \
        -out "$WORK_DIR/${name}.csr" \
        -config "$WORK_DIR/${name}.cnf"

    openssl x509 -req \
        -in "$WORK_DIR/${name}.csr" \
        -CA "$CERTS_DIR/ca.crt" \
        -CAkey "$CERTS_DIR/ca.key" \
        -CAcreateserial -CAserial "$WORK_DIR/ca.srl" \
        -out "$CERTS_DIR/${name}.crt" \
        -days "$LEAF_DAYS" -sha256 \
        -extfile "$WORK_DIR/${name}.cnf" -extensions v3_req
}

if certs_valid; then
    fix_perms
    echo "[tls-init] Certificats TLS valides deja presents dans ${CERTS_DIR}."
    exit 0
fi

echo "[tls-init] Generation de l'AC locale et des certificats TLS (evebox, grafana)..."

cat > "$WORK_DIR/ca.cnf" <<'EOF'
[req]
prompt = no
distinguished_name = dn
x509_extensions = v3_ca

[dn]
O = Suricata-NDR-DMZ
OU = Groupe 2
CN = Suricata-NDR-DMZ Local CA

[v3_ca]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
EOF

openssl req -x509 -new -nodes -newkey rsa:2048 \
    -days "$CA_DAYS" -sha256 \
    -keyout "$CERTS_DIR/ca.key" \
    -out "$CERTS_DIR/ca.crt" \
    -config "$WORK_DIR/ca.cnf"

issue_cert "evebox" "evebox" "DNS:evebox,DNS:localhost,IP:127.0.0.1,IP:172.20.0.14"
issue_cert "grafana" "grafana" "DNS:grafana,DNS:localhost,IP:127.0.0.1"

fix_perms
openssl verify -CAfile "$CERTS_DIR/ca.crt" "$CERTS_DIR/evebox.crt"
openssl verify -CAfile "$CERTS_DIR/ca.crt" "$CERTS_DIR/grafana.crt"
echo "[tls-init] Certificats prets dans ${CERTS_DIR}."
