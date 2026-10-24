#!/usr/bin/env bash
# Перевод уже установленного узла на новый домен без переустановки.
#
# Использование (на самом узле, от root):
#   bash migrate_domain.sh <old-domain> <new-domain>
#
# Что делает (идемпотентно, старый домен остаётся рабочим):
#   1. Caddy: добавляет новый домен в адреса сайта, ждёт сертификат ACME.
#   2. x-ui:  Reality serverNames, TLS-сертификат и serverName Hysteria2,
#             subURI и сертификаты панели/подписки переключаются на новый домен.
#             Новый домен ставится первым, старый остаётся допустимым.
#   3. Перезапускает caddy и x-ui, проверяет, что узел отвечает на новый домен.
#
# Бэкапы лежат в /root/domain-migration-<timestamp>/. Откат: вернуть Caddyfile и
# x-ui.db из бэкапа и выполнить `systemctl restart caddy x-ui`.
#
# DNS нового домена (A-запись на IP узла) должен существовать заранее.

set -euo pipefail

OLD="${1:-}"
NEW="${2:-}"
[[ -n "$OLD" && -n "$NEW" && "$OLD" != "$NEW" ]] || {
    echo "usage: $0 <old-domain> <new-domain>" >&2
    exit 2
}

CADDYFILE="/etc/caddy/Caddyfile"
CADDY_DATA_DIR="/var/lib/caddy"
XUI_DB="/etc/x-ui/x-ui.db"
CERT_WAIT_SECONDS=240

log() { printf '[migrate-domain] %s\n' "$*"; }
die() { printf '[migrate-domain] ERROR: %s\n' "$*" >&2; exit 1; }

cert_file() { find "$CADDY_DATA_DIR" -path "*certificates*/$1/$1.crt" 2>/dev/null | head -1 || true; }
key_file()  { find "$CADDY_DATA_DIR" -path "*certificates*/$1/$1.key" 2>/dev/null | head -1 || true; }

[[ $EUID -eq 0 ]] || die "run as root"
[[ -f "$CADDYFILE" ]] || die "$CADDYFILE not found"
[[ -f "$XUI_DB" ]] || die "$XUI_DB not found"
command -v python3 >/dev/null || die "python3 is required"

BACKUP_DIR="/root/domain-migration-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BACKUP_DIR"
cp -a "$CADDYFILE" "$BACKUP_DIR/Caddyfile"
cp -a "$XUI_DB" "$BACKUP_DIR/x-ui.db"
log "backups: $BACKUP_DIR"

# ── 1. Caddy ────────────────────────────────────────────────────────────────
if grep -q "https://${NEW}" "$CADDYFILE"; then
    log "Caddyfile already serves $NEW"
else
    log "Caddyfile: adding $NEW next to $OLD"
    sed -i \
        -e "s#^http://${OLD} {#http://${OLD}, http://${NEW} {#" \
        -e "s#^https://${OLD} {#https://${OLD}, https://${NEW} {#" \
        -e "s#redir https://${OLD}{uri}#redir https://{host}{uri}#" \
        "$CADDYFILE"
    grep -q "https://${NEW}" "$CADDYFILE" || die "could not add $NEW to $CADDYFILE (unexpected format)"
    caddy validate --config "$CADDYFILE" >/dev/null 2>&1 || {
        cp -a "$BACKUP_DIR/Caddyfile" "$CADDYFILE"
        die "Caddyfile validation failed, original restored"
    }
    # admin off → reload через API недоступен, нужен рестарт.
    systemctl restart caddy
fi

if [[ -z "$(cert_file "$NEW")" ]]; then
    log "waiting for ACME certificate for $NEW (up to ${CERT_WAIT_SECONDS}s)"
    waited=0
    while [[ -z "$(cert_file "$NEW")" && $waited -lt $CERT_WAIT_SECONDS ]]; do
        sleep 5
        waited=$((waited + 5))
    done
fi
NEW_CERT="$(cert_file "$NEW")"
NEW_KEY="$(key_file "$NEW")"
if [[ -z "$NEW_CERT" || -z "$NEW_KEY" ]]; then
    log "no certificate for $NEW, restoring Caddyfile"
    cp -a "$BACKUP_DIR/Caddyfile" "$CADDYFILE"
    systemctl restart caddy
    journalctl -u caddy --no-pager -n 10 2>/dev/null | cut -c1-220 || true
    die "certificate for $NEW was not issued (check DNS and port 80)"
fi
log "certificate: $NEW_CERT"

# ── 2. x-ui ─────────────────────────────────────────────────────────────────
python3 - "$XUI_DB" "$OLD" "$NEW" "$NEW_CERT" "$NEW_KEY" <<'PY'
import json
import sqlite3
import sys

db_path, old, new, new_cert, new_key = sys.argv[1:6]
db = sqlite3.connect(db_path, timeout=30)
changes = []

for inbound_id, port, protocol, stream in db.execute(
    "SELECT id, port, protocol, stream_settings FROM inbounds"
).fetchall():
    data = json.loads(stream)
    changed = False
    security = data.get("security")

    if security == "reality":
        reality = data.setdefault("realitySettings", {})
        names = reality.get("serverNames") or []
        wanted = [new] + [n for n in names if n != new]
        if names != wanted:
            reality["serverNames"] = wanted
            changed = True
    elif security == "tls":
        tls = data.setdefault("tlsSettings", {})
        if tls.get("serverName") != new:
            tls["serverName"] = new
            changed = True
        certs = tls.get("certificates") or []
        if not any((c.get("certificateFile") or "") == new_cert for c in certs):
            template = dict(certs[0]) if certs else {
                "oneTimeLoading": False,
                "usage": "encipherment",
                "buildChain": False,
            }
            template["certificateFile"] = new_cert
            template["keyFile"] = new_key
            tls["certificates"] = [template] + certs
            changed = True

    if changed:
        db.execute(
            "UPDATE inbounds SET stream_settings = ? WHERE id = ?",
            (json.dumps(data, separators=(",", ":")), inbound_id),
        )
        changes.append(f"inbound {inbound_id} ({protocol}:{port})")

for key in ("subURI",):
    row = db.execute("SELECT value FROM settings WHERE key = ?", (key,)).fetchone()
    if row and old in row[0]:
        db.execute("UPDATE settings SET value = ? WHERE key = ?", (row[0].replace(old, new), key))
        changes.append(f"setting {key}")

for key, target in (
    ("webCertFile", new_cert),
    ("subCertFile", new_cert),
    ("webKeyFile", new_key),
    ("subKeyFile", new_key),
):
    row = db.execute("SELECT value FROM settings WHERE key = ?", (key,)).fetchone()
    if row and old in row[0] and row[0] != target:
        db.execute("UPDATE settings SET value = ? WHERE key = ?", (target, key))
        changes.append(f"setting {key}")

db.commit()
print("x-ui changes:", ", ".join(changes) if changes else "none (already migrated)")
PY

systemctl restart x-ui
for _ in $(seq 1 30); do
    systemctl is-active --quiet x-ui && break
    sleep 1
done
systemctl is-active --quiet x-ui || die "x-ui is not active after restart; restore $BACKUP_DIR/x-ui.db"

# ── 3. Проверка ─────────────────────────────────────────────────────────────
sleep 3
for name in "$NEW" "$OLD"; do
    subject=$(echo | openssl s_client -connect 127.0.0.1:443 -servername "$name" 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null || true)
    log "TLS on :443 for SNI $name -> ${subject:-no certificate}"
done
ss -ltnup 2>/dev/null | grep -E ':(443|63000) ' | awk '{print "  listening:", $5}' || true
log "done. Backups in $BACKUP_DIR"
