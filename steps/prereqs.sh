# shellcheck source=steps/_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)/_lib.sh"

info "Installing required packages..."
if command_exists apt-get; then
    install_packages \
        curl gnupg lsb-release ca-certificates apt-transport-https \
        sqlite3 apache2-utils dnsutils cron \
        || die "Failed to install required packages for Debian/Ubuntu."
elif command_exists yum; then
    install_packages \
        curl sqlite gnupg2 redhat-lsb-core ca-certificates bind-utils cronie \
        || die "Failed to install required packages for RHEL/CentOS."
else
    die "No supported package manager was found. apt-get or yum is required."
fi

if command_exists systemctl; then
    if command_exists cron || command_exists crond; then
        systemctl enable --now cron 2>/dev/null || systemctl enable --now crond 2>/dev/null || true
    fi
fi

command_exists crontab || die "The crontab command is unavailable after installing cron/cronie."

success "Required packages installed."
