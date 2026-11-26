#!/usr/bin/env python3
"""Notifier Suricata -> Mailpit.

Lit eve.json en continu (comme `tail -F`), filtre les alertes selon leur
severite (1 = la plus grave) et envoie un e-mail par alerte via SMTP.
Un delai anti-doublon evite d'inonder la boite pour un meme attaquant et une
meme signature (ex. un scan qui declenche des centaines d'alertes).
"""
import json
import os
import smtplib
import sys
import time
from email.message import EmailMessage

EVE_PATH = os.environ.get("EVE_PATH", "/var/log/suricata/eve.json")
SMTP_HOST = os.environ.get("SMTP_HOST", "mailpit")
SMTP_PORT = int(os.environ.get("SMTP_PORT", "1025"))
MAIL_FROM = os.environ.get("MAIL_FROM", "suricata@dmz.local")
MAIL_TO = os.environ.get("MAIL_TO", "soc@dmz.local")
MAX_SEVERITY = int(os.environ.get("NOTIFY_MAX_SEVERITY", "2"))  # 1 et 2
COOLDOWN = int(os.environ.get("NOTIFY_COOLDOWN_SECONDS", "60"))
SEVERITY_LABEL = {1: "CRITICAL", 2: "HIGH", 3: "MEDIUM"}

last_sent = {}


def log(msg):
    print(f"[notifier] {msg}", flush=True)


def build_mail(ev):
    alert = ev["alert"]
    sev = alert.get("severity", 3)
    label = SEVERITY_LABEL.get(sev, f"SEV{sev}")
    src = f"{ev.get('src_ip')}:{ev.get('src_port', '-')}"
    dst = f"{ev.get('dest_ip')}:{ev.get('dest_port', '-')}"

    lines = [
        f"Signature : {alert.get('signature')}",
        f"SID       : {alert.get('signature_id')}",
        f"Categorie : {alert.get('category')}",
        f"Severite  : {sev} ({label})",
        f"Horodatage: {ev.get('timestamp')}",
        f"Flux      : {src} -> {dst} ({ev.get('proto')})",
    ]
    http = ev.get("http")
    if http:
        lines += [
            f"HTTP      : {http.get('http_method')} {http.get('hostname')}{http.get('url')}",
            f"User-Agent: {http.get('http_user_agent')}",
        ]
    dns = ev.get("dns")
    if dns:
        lines.append(f"DNS       : {dns.get('rrname')}")

    msg = EmailMessage()
    msg["Subject"] = f"[Suricata][{label}] {alert.get('signature')}"
    msg["From"] = MAIL_FROM
    msg["To"] = MAIL_TO
    msg.set_content("\n".join(lines) + "\n")
    return msg


def send(msg):
    # Mailpit peut demarrer apres le notifier : quelques tentatives.
    for attempt in range(1, 6):
        try:
            with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=10) as smtp:
                smtp.send_message(msg)
            return True
        except OSError as exc:
            log(f"SMTP indisponible ({exc}), tentative {attempt}/5")
            time.sleep(2 * attempt)
    return False


def handle(line):
    try:
        ev = json.loads(line)
    except ValueError:
        return
    if ev.get("event_type") != "alert":
        return
    alert = ev.get("alert", {})
    if alert.get("severity", 3) > MAX_SEVERITY:
        return

    key = (alert.get("signature_id"), ev.get("src_ip"))
    now = time.monotonic()
    if now - last_sent.get(key, -COOLDOWN) < COOLDOWN:
        return
    last_sent[key] = now

    if send(build_mail(ev)):
        log(f"mail envoye : {alert.get('signature')} ({ev.get('src_ip')})")
    else:
        log(f"echec d'envoi : {alert.get('signature')}")


def follow(path):
    """Generateur de lignes, tolerant a la rotation et a l'absence du fichier."""
    while not os.path.exists(path):
        time.sleep(1)
    f = open(path, "r", encoding="utf-8", errors="replace")
    f.seek(0, os.SEEK_END)  # on ignore l'historique : seulement le nouveau
    inode = os.fstat(f.fileno()).st_ino
    while True:
        line = f.readline()
        if line:
            yield line
            continue
        time.sleep(0.5)
        try:
            st = os.stat(path)
        except FileNotFoundError:
            continue
        if st.st_ino != inode or st.st_size < f.tell():  # rotation / troncature
            f.close()
            f = open(path, "r", encoding="utf-8", errors="replace")
            inode = os.fstat(f.fileno()).st_ino


def main():
    log(f"surveillance de {EVE_PATH}, severite <= {MAX_SEVERITY}, "
        f"destinataire {MAIL_TO} via {SMTP_HOST}:{SMTP_PORT}")
    for line in follow(EVE_PATH):
        handle(line)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
