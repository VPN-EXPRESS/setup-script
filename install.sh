#!/usr/bin/env bash
# =============================================================================
# install.sh — запускает установку прямо на сервере без deploy.sh
#
# Использование на VPS:
#   bash <(curl -sL https://raw.githubusercontent.com/VPN-EXPRESS/setup-script/main/install.sh) \
#       --domain vpn.example.com --ip 1.2.3.4 --email admin@example.com
# =============================================================================
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STEPS_DIR="$SCRIPT_ROOT/steps"
REPO_REMOTE_URL="${REPO_REMOTE_URL:-https://github.com/VPN-EXPRESS/setup-script.git}"
REPO_ARCHIVE_URL="${REPO_ARCHIVE_URL:-https://github.com/VPN-EXPRESS/setup-script/archive/refs/heads/main.tar.gz}"
QUIET=0
VERBOSE=0

usage() {
        cat <<'USAGE'
Usage:
    bash install.sh --domain DOMAIN --ip IP --email EMAIL [options]

Required arguments:
    --domain DOMAIN       Server domain
    --ip IP               Public server IP
    --email EMAIL         Email used for the ACME certificate

Optional arguments:
    --username NAME       Panel username (default: admin)
    --password PASSWORD   Panel password (default: admin)
    -h, --help            Show this help
    -q, --quiet           Show only errors
    -v, --verbose         Enable detailed debug output
USAGE
}

die_cli() { printf '[ERROR] %s\n' "$*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
        case "$1" in
                --domain) [[ $# -ge 2 ]] || die_cli "Value required for --domain."; DOMAIN="$2"; shift 2 ;;
                --ip) [[ $# -ge 2 ]] || die_cli "Value required for --ip."; SERVER_IP="$2"; shift 2 ;;
                --email) [[ $# -ge 2 ]] || die_cli "Value required for --email."; ACME_EMAIL="$2"; shift 2 ;;
                --username) [[ $# -ge 2 ]] || die_cli "Value required for --username."; PANEL_USER="$2"; shift 2 ;;
                --password) [[ $# -ge 2 ]] || die_cli "Value required for --password."; PANEL_PASS="$2"; shift 2 ;;
                -h|--help) usage; exit 0 ;;
                -q|--quiet) QUIET=1; shift ;;
                -v|--verbose) VERBOSE=1; shift ;;
                --) shift; [[ $# -eq 0 ]] || die_cli "Unknown parameter: $1" ;;
                -*) die_cli "Unknown parameter: $1" ;;
                *) die_cli "Unexpected argument: $1" ;;
        esac
done

[[ -n "${DOMAIN:-}" ]] || die_cli "Required parameter --domain is missing."
[[ -n "${SERVER_IP:-}" ]] || die_cli "Required parameter --ip is missing."
[[ -n "${ACME_EMAIL:-}" ]] || die_cli "Required parameter --email is missing."
PANEL_USER="${PANEL_USER:-admin}"
PANEL_PASS="${PANEL_PASS:-admin}"
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die_cli "Invalid domain: $DOMAIN"
[[ "$SERVER_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die_cli "Invalid IPv4 address: $SERVER_IP"
IFS=. read -r ip_octet_1 ip_octet_2 ip_octet_3 ip_octet_4 <<<"$SERVER_IP"
for ip_octet in "$ip_octet_1" "$ip_octet_2" "$ip_octet_3" "$ip_octet_4"; do
    (( ip_octet <= 255 )) || die_cli "Invalid IPv4 address: $SERVER_IP"
done
[[ "$ACME_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die_cli "Invalid email: $ACME_EMAIL"
export DOMAIN SERVER_IP ACME_EMAIL PANEL_USER PANEL_PASS QUIET VERBOSE

TEMP_ROOT=""
cleanup() { [[ -n "$TEMP_ROOT" ]] && rm -rf "$TEMP_ROOT"; }
trap cleanup EXIT

if [[ ! -f "$STEPS_DIR/setup.sh" ]]; then
        TEMP_ROOT=$(mktemp -d) || die_cli "Failed to create a temporary directory."

        if command -v git >/dev/null 2>&1; then
                git clone --depth 1 "$REPO_REMOTE_URL" "$TEMP_ROOT/repo" >/dev/null 2>&1 \
                        || die_cli "Failed to clone the installer repository."
                SCRIPT_ROOT="$TEMP_ROOT/repo"
        else
                command -v curl >/dev/null 2>&1 || die_cli "curl or git is required for remote installation."
                curl -fsSL --retry 3 "$REPO_ARCHIVE_URL" | tar -xz -C "$TEMP_ROOT" \
                        || die_cli "Failed to download the installer files."
                SCRIPT_ROOT=$(find "$TEMP_ROOT" -mindepth 1 -maxdepth 1 -type d -print -quit)
        fi

        STEPS_DIR="$SCRIPT_ROOT/steps"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && die "Run this script as root: sudo bash install.sh"
[[ -d "$STEPS_DIR" ]] || die_cli "The steps directory was not found."
[[ -f "$STEPS_DIR/setup.sh" ]] || die_cli "The file steps/setup.sh was not found."

[[ "$VERBOSE" -eq 1 ]] && export DEBUG=1

[[ "$QUIET" -eq 0 ]] && info "Preparing step scripts..."
chmod +x "$STEPS_DIR"/*.sh

echo
[[ "$QUIET" -eq 0 ]] && info "Starting installation on this server (domain: ${DOMAIN})..."
[[ "$QUIET" -eq 0 ]] && info "Progress and detailed logs are written to /root/3xui-install-full.log (press Ctrl+C to abort)..."
echo

if [[ "$VERBOSE" -eq 1 ]]; then
    setup_command=(bash -x "$STEPS_DIR/setup.sh")
else
    setup_command=(bash "$STEPS_DIR/setup.sh")
fi

if "${setup_command[@]}"; then
    if [[ "$QUIET" -eq 0 ]]; then
        echo
        success "Installation completed successfully."
        echo
        info "Credentials:"
        cat /root/3xui-credentials.txt 2>/dev/null || echo "(credentials file not found)"
    fi
else
    echo
    die "Installation did not complete. Review the log: /root/3xui-install-full.log"
fi
