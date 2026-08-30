#!/usr/bin/env bash
# =============================================================================
# deploy.sh — заливает steps/ на сервер и запускает setup.sh
#
# Использование:
#   bash deploy.sh <IP>
#   bash deploy.sh <IP> -i ~/.ssh/id_rsa   # явно указать ключ
#   SSH_PORT=2222 bash deploy.sh <IP>       # нестандартный порт
#   DOMAIN=vpn.example.com bash deploy.sh <IP>
# =============================================================================
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/local_lib.sh
source "$SCRIPT_ROOT/scripts/local_lib.sh"

# ─── Arguments ────────────────────────────────────────────────────────────────
SERVER_IP="${1:-}"
[[ -z "$SERVER_IP" ]] && die "Specify the server IP: bash deploy.sh <IP>"
shift

REMOTE_DIR="${REMOTE_DIR:-/root/3xui-setup}"
SSH_EXTRA=("$@")
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-5}"
init_ssh_options

STEPS_DIR="$SCRIPT_ROOT/steps"

# ─── Домен ────────────────────────────────────────────────────────────────────
if [[ -z "${DOMAIN:-}" ]]; then
    read -rp "Enter the domain (for example, vpn.example.com): " DOMAIN
    [[ -z "$DOMAIN" ]] && die "Domain cannot be empty."
fi

# Локальные переопределения должны попасть в удалённый setup.sh.
REMOTE_ENV_VARS=(
    DOMAIN
    PANEL_PORT PANEL_USER PANEL_PASS PANEL_PATH
    SUB_PORT SUB_PATH SUB_TITLE
    OPERA_REGION HY2_PORT HY2_HOP HY2_HOP_RANGE
    VLESS_PORT TROJAN_PORT TROJAN_WS_PATH TRAFFIC_RESET
)
remote_env_assignments=()
for var_name in "${REMOTE_ENV_VARS[@]}"; do
    var_value="${!var_name:-}"
    [[ -z "$var_value" ]] && continue
    remote_env_assignments+=("${var_name}=$(shell_quote "$var_value")")
done
remote_env_prefix="${remote_env_assignments[*]}"

# ─── Waiting for SSH ─────────────────────────────────────────────────────────────
info "Waiting for SSH on ${SSH_USER}@${SERVER_IP}:${SSH_PORT}..."
WAIT_MAX=30; WAIT_STEP=5; elapsed=0
while true; do
    ssh_error=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SERVER_IP}" 'exit 0' 2>&1) && break
    if grep -q "REMOTE HOST IDENTIFICATION HAS CHANGED" <<<"$ssh_error"; then
        warn "The SSH host key for ${SERVER_IP} changed (server was reinstalled or replaced)."
        read -rp "Remove the old key and continue? [Y/n] " _key_ans
        if [[ -z "$_key_ans" || "$(echo "$_key_ans" | tr '[:upper:]' '[:lower:]')" == "y" ]]; then
            ssh-keygen -R "${SERVER_IP}" 2>/dev/null || true
            info "The old key was removed. Retrying connection..."
            continue
        fi
        die "Aborted. Remove it manually: ssh-keygen -R ${SERVER_IP}"
    fi
    (( elapsed >= WAIT_MAX )) && die "SSH is unavailable after ${WAIT_MAX}s."
    warn "Connection unavailable; retrying in ${WAIT_STEP}s... (${elapsed}/${WAIT_MAX}s)"
    sleep "$WAIT_STEP"
    (( elapsed += WAIT_STEP ))
done
success "SSH is reachable."

# ─── Бэкап при повторном деплое ──────────────────────────────────────────────
_has_existing=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SERVER_IP}" \
    'test -f /root/3xui-credentials.txt && echo yes || echo no' 2>/dev/null || echo no)
if [[ "$_has_existing" == "yes" ]]; then
    warn "An existing installation was detected on the server."
    read -rp "Create a backup before deployment? [Y/n] " _bk_ask
    if [[ -z "$_bk_ask" || "$(echo "$_bk_ask" | tr '[:upper:]' '[:lower:]')" == "y" ]]; then
        if SSH_PORT="$SSH_PORT" SSH_USER="$SSH_USER" \
           bash "$SCRIPT_ROOT/backup.sh" "$SERVER_IP" ${SSH_EXTRA[@]+"${SSH_EXTRA[@]}"}; then
            success "Backup created successfully."
        else
            warn "Backup failed."
            read -rp "Continue deployment without a backup? [Y/n] " _bk_ans
            [[ -z "$_bk_ans" || "$(echo "$_bk_ans" | tr '[:upper:]' '[:lower:]')" == "y" ]] || die "Aborted."
        fi
    else
        warn "Backup skipped."
    fi
fi

# ─── Copying files ──────────────────────────────────────────────────────────────
echo
info "Copying files to ${REMOTE_DIR}/..."
remote_dir_q=$(shell_quote "$REMOTE_DIR")
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SERVER_IP}" "mkdir -p ${remote_dir_q}"
scp "${SCP_OPTS[@]}" "$STEPS_DIR"/*.sh "${SSH_USER}@${SERVER_IP}:${remote_dir_q}/"
success "Files copied successfully."

# ─── Running setup ───────────────────────────────────────────────────────────────────
echo
info "Starting setup.sh on the server (domain: ${DOMAIN})..."
echo

info "Progress and detailed logs are available in /root/3xui-install-full.log (press Ctrl+C to abort)..."
echo

if ssh -t "${SSH_OPTS[@]}" "${SSH_USER}@${SERVER_IP}" \
    "find ${remote_dir_q} -name '*.sh' -exec chmod +x {} +; \
     rm -f /root/3xui-install.log /root/3xui-install-full.log; \
     touch /root/3xui-install.log; \
     ${remote_env_prefix} bash ${remote_dir_q}/setup.sh"; then
    echo
    success "Deployment completed successfully."

    # ─── Results ─────────────────────────────────────────────────────────────────────
    echo
    info "Credentials:"
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SERVER_IP}" "cat /root/3xui-credentials.txt 2>/dev/null || echo '(credentials file not found)'"

    # ─── Healthcheck ──────────────────────────────────────────────────────────
    # Validate the local HTTPS backend for x-ui. This avoids hairpin NAT issues and
    # avoids querying the public domain from the server itself, which is unreliable on many VPS setups.
    echo
    info "Checking panel availability..."
    _hc_code=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SERVER_IP}" bash <<'HCHECK' 2>/dev/null || echo error
db=/etc/x-ui/x-ui.db
command -v sqlite3 >/dev/null 2>&1 || { echo no_sqlite; exit 0; }
[[ -f "$db" ]] || { echo no_db; exit 0; }
port=$(sqlite3 "$db" "SELECT value FROM settings WHERE key='webPort';" 2>/dev/null)
base=$(sqlite3 "$db" "SELECT value FROM settings WHERE key='webBasePath';" 2>/dev/null)
[[ -z "$port" ]] && { echo no_port; exit 0; }
curl -sk --max-time 15 "https://127.0.0.1:${port}${base}" -o /dev/null -w "%{http_code}" 2>/dev/null || echo 000
HCHECK
    )
    if [[ "$_hc_code" =~ ^[23][0-9]{2}$ ]]; then
        success "The panel is responding locally with HTTP ${_hc_code}. Open it using the URL from the credentials output."
    elif [[ "$_hc_code" == no_* ]]; then
        warn "Healthcheck skipped (${_hc_code}). Review the panel using the URL from the credentials output."
    else
        warn "The panel backend is not responding locally (code: ${_hc_code}). Check: systemctl status x-ui; journalctl -u x-ui -n 100"
    fi
else
    echo
    die "Deployment did not complete. Review the log on the server: /root/3xui-install-full.log"
fi
