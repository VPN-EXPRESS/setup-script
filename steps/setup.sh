#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Logging ─────────────────────────────────────────────────────────────────────
# All stdout/stderr output is redirected to the full log file.
# info/success/warn/die write to the filtered log only.
LOGFILE=/root/3xui-install.log
FULL_LOGFILE=/root/install.log
export LOGFILE FULL_LOGFILE
mkdir -p "$(dirname "$LOGFILE")"
mkdir -p "$(dirname "$FULL_LOGFILE")"
exec 3>&1 >>"$FULL_LOGFILE" 2>&1
printf "%s\n" "[$(date '+%Y-%m-%d %H:%M:%S')] ══════ Setup started ══════" >>"$FULL_LOGFILE"
printf "%s\n" "[INFO]  Setup started. Full log: $FULL_LOGFILE" >>"$LOGFILE"
printf "%s\n" "[INFO]  Setup started. Full log: $FULL_LOGFILE" >&3

# shellcheck source=steps/_lib.sh
source "$SCRIPT_DIR/_lib.sh"
[[ "${DEBUG:-0}" -eq 1 ]] && set -x

info "Full installation log: $FULL_LOGFILE"
trap 'printf "[$(date +%T)] ABORT\n" >> "$FULL_LOGFILE"; printf "[ERROR] Installation interrupted. Details: %s\n" "$FULL_LOGFILE" >> "$LOGFILE"; printf "[ERROR] Installation interrupted. Details: %s\n" "$FULL_LOGFILE" >&3; exit 1' ERR

if truthy "${LOW_POWER_MODE:-0}"; then
    warn "LOW_POWER_MODE enabled: reducing background load and suppressing noisy services."
fi

# ─── Run steps as subprocesses ───────────────────────────────────────────
_run_step() {
    local label="$1" script="$2"
    local line
    line="[$(date '+%H:%M:%S')] ── $label"
    [[ "${QUIET:-0}" -eq 1 ]] || printf "\n%s\n" "$line"
    printf "\n%s\n" "$line" >>"$LOGFILE"
    printf "\n%s\n" "$line" >&3
    spinner_run "[${label}] in progress..." bash "$script"
}

_run_step "Prereqs"     "$SCRIPT_DIR/prereqs.sh"
_run_step "BBR"         "$SCRIPT_DIR/bbr.sh"
_run_step "WARP"        "$SCRIPT_DIR/warp.sh"
_run_step "Opera Proxy" "$SCRIPT_DIR/opera-proxy.sh"
_run_step "Tor"         "$SCRIPT_DIR/tor.sh"

if truthy "${LOW_POWER_MODE:-0}"; then
    info "LOW_POWER_MODE: fail2ban step skipped to reduce unnecessary load on a low-power server."
else
    _run_step "fail2ban"    "$SCRIPT_DIR/fail2ban.sh"
fi

_run_step "Selfsteal"   "$SCRIPT_DIR/selfsteal.sh"
_run_step "3x-ui"       "$SCRIPT_DIR/xui.sh"

# ─── Save credentials ────────────────────────────────────────────────────────
_cert_path=$(caddy_cert_file)
cat > /root/setup-result.env <<CREDS
Installation date : $(date '+%Y-%m-%d %H:%M:%S')
Panel URL         : https://${DOMAIN}${PANEL_PATH}
Username          : ${PANEL_USER}
Password          : ${PANEL_PASS}
Selfsteal         : https://${DOMAIN}
Certificate       : ${_cert_path:-<Caddy directory: ${CADDY_DATA_DIR}>}
WARP SOCKS5       : 127.0.0.1:${WARP_PROXY_PORT}
Opera SOCKS5      : 127.0.0.1:${OPERA_PROXY_PORT} (region: ${OPERA_REGION})
Tor SOCKS5        : 127.0.0.1:${TOR_PORT}
CREDS
chmod 600 /root/setup-result.env

echo "--- SETUP DONE ---"
printf "%s\n" "--- SETUP DONE ---" >>"$LOGFILE"
printf "%s\n" "--- SETUP DONE ---" >&3
