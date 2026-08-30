#!/usr/bin/env bash
# =============================================================================
# steps/restore.sh — серверное восстановление 3x-ui (запускается на сервере)
#
# Использование:
#   bash /root/3xui-setup/restore.sh                        # интерактивный выбор
#   bash /root/3xui-setup/restore.sh <файл.tar.gz>          # явно указать файл
#   bash /root/3xui-setup/restore.sh latest                 # последний бекап
#
# Архивы ищутся в /root/backups/
# =============================================================================
set -euo pipefail

XUI_DIR="/root"
BACKUP_DIR="${BACKUP_DIR:-/root/backups}"

# ─── Выбор файла ─────────────────────────────────────────────────────────────
ARG="${1:-}"

if [[ "$ARG" == "latest" ]]; then
    BACKUP_FILE=$(ls -t "${BACKUP_DIR}"/3xui_*.tar.gz 2>/dev/null | head -1 || true)
    [[ -z "$BACKUP_FILE" ]] && { echo "[ERROR] No backups found in ${BACKUP_DIR}"; exit 1; }
elif [[ -n "$ARG" ]]; then
    # Принимаем как абсолютный путь или имя файла в BACKUP_DIR
    if [[ -f "$ARG" ]]; then
        BACKUP_FILE="$ARG"
    elif [[ -f "${BACKUP_DIR}/${ARG}" ]]; then
        BACKUP_FILE="${BACKUP_DIR}/${ARG}"
    else
        echo "[ERROR] File not found: $ARG"; exit 1
    fi
else
    # Интерактивный выбор
    mapfile -t backups < <(ls -t "${BACKUP_DIR}"/3xui_*.tar.gz 2>/dev/null || true)
    if [[ ${#backups[@]} -eq 0 ]]; then
        echo "[ERROR] No backups found in ${BACKUP_DIR}"; exit 1
    fi
    echo "Available backups:"
    for i in "${!backups[@]}"; do
        size=$(du -sh "${backups[$i]}" 2>/dev/null | cut -f1)
        printf "  [%d] %s  (%s)\n" "$((i+1))" "$(basename "${backups[$i]}")" "$size"
    done
    read -rp "Select a backup number [1]: " choice
    choice="${choice:-1}"
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#backups[@]} )); then
        echo "[ERROR] Invalid selection."; exit 1
    fi
    BACKUP_FILE="${backups[$((choice-1))]}"
fi

echo
echo "[WARN] Existing data will be replaced with the backup contents."
echo "[WARN] Backup file: ${BACKUP_FILE}"
read -rp "Continue? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[yY]$ ]] || { echo "[INFO] Restore cancelled."; exit 0; }

# ─── Восстановление ───────────────────────────────────────────────────────────
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "[INFO] Stopping services..."
systemctl stop x-ui 2>/dev/null || true
systemctl stop caddy 2>/dev/null || true

echo "[INFO] Extracting the backup archive..."
tar -xzf "$BACKUP_FILE" -C "$TMP_DIR"

# Нативный x-ui: БД в /etc/x-ui. Поддерживаем и старый формат бекапа (db/).
if [[ -d "$TMP_DIR/etc-x-ui" ]]; then
    echo "[INFO] Restoring /etc/x-ui/..."
    mkdir -p /etc/x-ui
    cp -a "$TMP_DIR/etc-x-ui/." /etc/x-ui/
elif [[ -d "$TMP_DIR/db" ]]; then
    echo "[INFO] Restoring the database from the legacy backup (db/) to /etc/x-ui/..."
    mkdir -p /etc/x-ui
    cp -a "$TMP_DIR/db/." /etc/x-ui/
fi

# Сертификат восстанавливается вместе с ACME-данными Caddy (/var/lib/caddy) ниже.
# Старый формат бекапа с cert/ совместимости ради копируем в /root/cert (не обязателен).
if [[ -d "$TMP_DIR/cert" ]]; then
    echo "[INFO] Restoring the legacy ${XUI_DIR}/cert/ directory..."
    mkdir -p "${XUI_DIR}/cert"
    cp -a "$TMP_DIR/cert/." "${XUI_DIR}/cert/"
    find "${XUI_DIR}/cert" \( -name "*.key" -o -name "privkey.pem" \) -exec chmod 600 {} +
    find "${XUI_DIR}/cert" \( \( -name "*.pem" ! -name "privkey.pem" \) -o -name "*.crt" \) -exec chmod 644 {} +
fi

# Caddy: конфиг, сайт-заглушка и ACME-данные
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

if [[ -f "$TMP_DIR/setup-result.env" ]]; then
    echo "[INFO] Restoring setup-result.env..."
    cp "$TMP_DIR/setup-result.env" /root/setup-result.env
fi

echo "[INFO] Starting services..."
systemctl start caddy 2>/dev/null && echo "[OK] Caddy started." \
    || echo "[WARN] Unable to start Caddy. Is it installed?"
systemctl start x-ui 2>/dev/null && echo "[OK] 3x-ui started." \
    || echo "[WARN] Unable to start x-ui. Is it installed?"

echo
echo "[OK] Restore completed from: $(basename "$BACKUP_FILE")"
