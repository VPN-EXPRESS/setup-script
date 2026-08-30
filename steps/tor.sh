# shellcheck source=steps/_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)/_lib.sh"

info "Installing Tor..."

# Idempotency: если Tor уже слушает нужный порт — пропускаем
if systemctl is-active --quiet tor 2>/dev/null && port_listening "$TOR_PORT"; then
    info "Tor is already running on port ${TOR_PORT}; skipping."
    exit 0
fi

install_packages tor || die "Failed to install Tor."

# Минимальный torrc — только SOCKS5 на localhost
cat > /etc/tor/torrc <<EOF
SocksPort 127.0.0.1:${TOR_PORT}
SocksPolicy accept 127.0.0.1
Log notice syslog
DataDirectory /var/lib/tor
EOF

systemctl enable tor
systemctl restart tor

if wait_for_tcp_port "$TOR_PORT" 30; then
    success "Tor is running. SOCKS5 proxy: 127.0.0.1:${TOR_PORT}"
else
    warn "Tor is not listening on port ${TOR_PORT}. Check: systemctl status tor"
fi
