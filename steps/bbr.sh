# shellcheck source=steps/_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)/_lib.sh"

info "Enabling BBR..."

if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    info "BBR is already enabled; skipping."
else
    grep -qxF 'net.core.default_qdisc=fq' /etc/sysctl.conf \
        || echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf
    grep -qxF 'net.ipv4.tcp_congestion_control=bbr' /etc/sysctl.conf \
        || echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf
    sysctl -p &>/dev/null
    success "BBR enabled."
fi
