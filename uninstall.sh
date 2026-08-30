#!/usr/bin/env bash
set -euo pipefail

FORCE=0
REMOVE_REPO=0
REMOVE_BACKUPS=0

usage() {
    cat <<'USAGE'
Usage:
    sudo bash uninstall.sh [--force] [--remove-repo] [--remove-backups]

Removes components installed by the project:
  - x-ui / Xray
  - Caddy
  - Tor
  - Cloudflare WARP
  - Opera Proxy
  - fail2ban
  - project configs / systemd units / installation directories

Options:
  --force          Skip the confirmation prompt
  --remove-repo    Also delete the cloned project directory (for example /root/3xui-setup)
  --remove-backups Remove local backup archives in /root/backups
  -h, --help       Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE=1; shift ;;
        --remove-repo) REMOVE_REPO=1; shift ;;
        --remove-backups) REMOVE_BACKUPS=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "[ERROR] Run as root: sudo bash uninstall.sh" >&2
    exit 1
fi

print_section() {
    echo
    echo "===== $1 ====="
}

warn() { echo "[WARN] $*" >&2; }
info() { echo "[INFO] $*"; }

if [[ "$FORCE" -eq 0 ]]; then
    echo
    echo "This script will remove the VPN stack installed by this project."
    echo "It will stop and uninstall: x-ui, Caddy, Tor, WARP, Opera Proxy, fail2ban."
    echo "It will also wipe the generated configuration files and service units."
    echo
    read -r -p "Continue? [y/N]: " answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        echo "Uninstall cancelled."
        exit 0
    fi
fi

print_section "Stopping services"
for unit in x-ui caddy tor opera-proxy warp-svc cloudflare-warp; do
    if systemctl list-unit-files --type=service --all 2>/dev/null | awk '{print $1}' | grep -qx "$unit"; then
        systemctl stop "$unit" 2>/dev/null || true
        systemctl disable "$unit" 2>/dev/null || true
    fi
done
systemctl daemon-reload 2>/dev/null || true

print_section "Removing packages"
for pkg in x-ui caddy fail2ban tor cloudflare-warp; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        info "Purging package: $pkg"
        apt-get purge -y "$pkg" || warn "Unable to purge $pkg"
    fi
done

if command -v apt-get >/dev/null 2>&1; then
    apt-get autoremove -y >/dev/null 2>&1 || true
    apt-get autoclean >/dev/null 2>&1 || true
fi

print_section "Removing binaries and service files"
rm -f /usr/bin/x-ui /usr/local/bin/opera-proxy /usr/local/bin/warp-cli /usr/local/bin/warp-svc 2>/dev/null || true
rm -f /etc/systemd/system/x-ui.service /etc/systemd/system/x-ui.service.d/override.conf 2>/dev/null || true
rm -f /etc/systemd/system/opera-proxy.service 2>/dev/null || true
rm -f /etc/systemd/system/caddy.service 2>/dev/null || true
rm -f /etc/systemd/system/tor.service 2>/dev/null || true
rm -f /etc/systemd/system/cloudflare-warp.service /etc/systemd/system/warp-svc.service 2>/dev/null || true
rm -rf /etc/systemd/system/x-ui.service.d 2>/dev/null || true
rm -rf /etc/systemd/system/opera-proxy.service.d 2>/dev/null || true

print_section "Removing application files"
rm -rf /usr/local/x-ui /etc/x-ui /var/lib/caddy /etc/caddy /var/www/html /var/lib/tor /etc/tor /var/lib/cloudflare-warp /etc/cloudflared 2>/dev/null || true
rm -rf /var/lib/opera-proxy /opt/opera-proxy /usr/local/share/opera-proxy* 2>/dev/null || true
rm -f /root/3xui-credentials.txt /root/3xui-install.log /root/3xui-install-full.log 2>/dev/null || true

print_section "Removing package repositories and keys"
rm -f /etc/apt/sources.list.d/caddy-stable.list /etc/apt/sources.list.d/cloudflare-client.list 2>/dev/null || true
rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null || true

if [[ "$REMOVE_BACKUPS" -eq 1 ]]; then
    print_section "Removing backup archives"
    rm -rf /root/backups 2>/dev/null || true
fi

if [[ "$REMOVE_REPO" -eq 1 ]]; then
    print_section "Removing project checkout"
    if [[ -d /root/3xui-setup ]]; then
        rm -rf /root/3xui-setup
    fi
    if [[ -d "$(pwd)" && "$(basename "$(pwd)")" == "setup" && -f "$(pwd)/install.sh" ]]; then
        warn "This script is currently running in the project checkout; refusing to delete the current working directory."
    fi
fi

print_section "Final cleanup"
for f in /etc/apt/sources.list.d/caddy-stable.list /etc/apt/sources.list.d/cloudflare-client.list; do
    [[ -e "$f" ]] && rm -f "$f" || true
done

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
fi

info "Uninstall finished. Some packages may still remain in the package cache until apt-get autoremove is run again."
info "If you want the project directory removed too, run: sudo bash uninstall.sh --remove-repo"
