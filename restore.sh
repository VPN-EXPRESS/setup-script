#!/usr/bin/env bash
# =============================================================================
# restore.sh — restores 3x-ui from a local backup onto the server
#
# Usage:
#   bash restore.sh <IP> <backup.tar.gz>
#   bash restore.sh <IP> <backup.tar.gz> -i ~/.ssh/id_rsa
#   SSH_PORT=2222 bash restore.sh <IP> <backup.tar.gz>
# =============================================================================
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/local_lib.sh
source "$SCRIPT_ROOT/scripts/local_lib.sh"

SERVER_IP="${1:-}"
BACKUP_FILE="${2:-}"
[[ -z "$SERVER_IP"   ]] && die "Specify the IP: bash restore.sh <IP> <backup.tar.gz>"
[[ -z "$BACKUP_FILE" ]] && die "Specify the backup file: bash restore.sh <IP> <backup.tar.gz>"
[[ -f "$BACKUP_FILE" ]] || die "File not found: $BACKUP_FILE"
shift 2

SSH_EXTRA=("$@")
init_ssh_options

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REMOTE_TMP="/tmp/3xui_restore_${TIMESTAMP}.tar.gz"

echo
warn "Warning: the current data on ${SERVER_IP} will be replaced by the backup contents."
warn "File: ${BACKUP_FILE}"
read -rp "Continue? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[yY]$ ]] || { info "Cancelled."; exit 0; }

info "Uploading the archive to the server..."
scp "${SCP_OPTS[@]}" "$BACKUP_FILE" "${SSH_USER}@${SERVER_IP}:${REMOTE_TMP}"

XUI_DIR="/root"

info "Restoring the data on the server..."
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SERVER_IP}" \
    XUI_DIR="${XUI_DIR}" REMOTE_TMP="${REMOTE_TMP}" bash <<'REMOTE'
set -euo pipefail

# Stop services
echo "[INFO] Stopping services..."
systemctl stop x-ui 2>/dev/null || true
systemctl stop caddy 2>/dev/null || true

# Extract to a temporary directory
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
tar -xzf "$REMOTE_TMP" -C "$TMP_DIR"

# Restore the native x-ui database (/etc/x-ui), including the legacy db/ layout
if [[ -d "$TMP_DIR/etc-x-ui" ]]; then
    echo "[INFO] Restoring /etc/x-ui/..."
    mkdir -p /etc/x-ui
    cp -a "$TMP_DIR/etc-x-ui/." /etc/x-ui/
elif [[ -d "$TMP_DIR/db" ]]; then
    echo "[INFO] Restoring the legacy database backup from db/ into /etc/x-ui/..."
    mkdir -p /etc/x-ui
    cp -a "$TMP_DIR/db/." /etc/x-ui/
fi

# Restore certificates
if [[ -d "$TMP_DIR/cert" ]]; then
    echo "[INFO] Restoring ${XUI_DIR}/cert/..."
    mkdir -p "${XUI_DIR}/cert"
    cp -a "$TMP_DIR/cert/." "${XUI_DIR}/cert/"
    find "${XUI_DIR}/cert" \( -name "*.key" -o -name "privkey.pem" \) -print | xargs -r chmod 600
    find "${XUI_DIR}/cert" \( \( -name "*.pem" ! -name "privkey.pem" \) -o -name "*.crt" \) -print | xargs -r chmod 644
fi

# Restore Caddy files (config, stub site, ACME data)
if [[ -f "$TMP_DIR/caddy-etc/Caddyfile" ]]; then
    echo "[INFO] Restoring /etc/caddy/Caddyfile..."
    mkdir -p /etc/caddy
    cp "$TMP_DIR/caddy-etc/Caddyfile" /etc/caddy/Caddyfile
fi
if [[ -d "$TMP_DIR/caddy-www" ]]; then
    echo "[INFO] Restoring /var/www/html/..."
    mkdir -p /var/www/html
    cp -a "$TMP_DIR/caddy-www/." /var/www/html/
    id caddy &>/dev/null && chown -R caddy:caddy /var/www/html 2>/dev/null || true
fi
if [[ -d "$TMP_DIR/caddy-data" ]]; then
    echo "[INFO] Restoring /var/lib/caddy/ (ACME certificate data)..."
    mkdir -p /var/lib/caddy
    cp -a "$TMP_DIR/caddy-data/." /var/lib/caddy/
    id caddy &>/dev/null && chown -R caddy:caddy /var/lib/caddy 2>/dev/null || true
fi

# Restore credentials file
if [[ -f "$TMP_DIR/3xui-credentials.txt" ]]; then
    cp "$TMP_DIR/3xui-credentials.txt" /root/3xui-credentials.txt
    chmod 600 /root/3xui-credentials.txt
fi

# Restore UFW rules
if [[ -f "$TMP_DIR/ufw-user.rules" ]] && command -v ufw &>/dev/null; then
    echo "[INFO] Restoring UFW rules..."
    cp "$TMP_DIR/ufw-user.rules"  /etc/ufw/user.rules
    [[ -f "$TMP_DIR/ufw-user6.rules" ]] && cp "$TMP_DIR/ufw-user6.rules" /etc/ufw/user6.rules
    ufw reload && echo "[OK] UFW rules restored."
fi

# Start services
echo "[INFO] Starting services..."
systemctl start caddy 2>/dev/null && echo "[OK] Caddy started." || echo "[WARN] Unable to start caddy (is it installed?)."
systemctl start x-ui 2>/dev/null && echo "[OK] 3x-ui started." || echo "[WARN] Unable to start x-ui (is it installed?)."

rm -f "$REMOTE_TMP"
echo "[OK] Restore completed."
REMOTE

echo
success "Restore completed."
