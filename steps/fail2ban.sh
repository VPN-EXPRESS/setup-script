# shellcheck source=steps/_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)/_lib.sh"

info "Installing fail2ban..."

if command_exists fail2ban-server; then
    info "fail2ban is already installed; skipping."
else
    info "Installing fail2ban..."
    install_packages fail2ban || warn "Failed to install fail2ban; skipping."
fi

if command_exists fail2ban-server; then
    systemctl enable --now fail2ban
    success "fail2ban installed and running."
else
    warn "fail2ban is not installed; activation skipped."
fi
