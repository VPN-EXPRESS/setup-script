#!/usr/bin/env bash
# Общие функции и переменные для шагов steps/
# Подключается автоматически при запуске шага напрямую.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Пишет прогресс в filtered log без ANSI-кодов.
# При прямом запуске шага также печатает в терминал.
_print() {
    local line plain_line
    line="$*"
    plain_line=$(printf '%s' "$line" | sed -r 's/\x1b\[[0-9;]*m//g')
    if [[ -n "${LOGFILE:-}" ]]; then
        printf '%s\n' "$plain_line" >>"$LOGFILE"
    fi
    if [[ "${QUIET:-0}" -eq 1 ]]; then
        return 0
    elif { true >&3; } 2>/dev/null; then
        echo -e "$line" >&3
    elif [[ -z "${FULL_LOGFILE:-}" ]]; then
        echo -e "$line"
    fi
}

info()    { _print "${CYAN}[INFO]${NC}  $*"; }
success() { _print "${GREEN}[OK]${NC}    $*"; }
warn()    { _print "${YELLOW}[WARN]${NC}  $*"; }
die()     {
    local line plain_line
    line="${RED}[ERROR]${NC} $*"
    plain_line=$(printf '%s' "$line" | sed -r 's/\x1b\[[0-9;]*m//g')
    if [[ -n "${LOGFILE:-}" ]]; then
        printf '%s\n' "$plain_line" >>"$LOGFILE"
    fi
    if { true >&3; } 2>/dev/null; then
        echo -e "$line" >&3
    elif [[ -z "${FULL_LOGFILE:-}" ]]; then
        echo -e "$line" >&2
    fi
    exit 1
}

command_exists() {
    command -v "$1" &>/dev/null
}

get_linux_id() {
    if [[ -r /etc/os-release ]]; then
        . /etc/os-release
        printf '%s' "${ID:-}"
    fi
}

default_dns_check_domain() {
    case "$(get_linux_id)" in
        ubuntu) printf '%s' "archive.ubuntu.com" ;;
        debian) printf '%s' "deb.debian.org" ;;
        *)      printf '%s' "deb.debian.org" ;;
    esac
}

dns_resolve_ipv4s() {
    local host="$1"
    getent ahosts "$host" 2>/dev/null \
        | awk '{print $1}' \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
        | sort -u || true
}

doh_resolve_ipv4s() {
    local host="$1" json

    if command_exists curl; then
        json=$(curl -fsSL --retry 2 --connect-timeout 5 --max-time 15 \
            --resolve cloudflare-dns.com:443:1.1.1.1 \
            -H 'accept: application/dns-json' \
            "https://cloudflare-dns.com/dns-query?name=${host}&type=A" 2>/dev/null || true)
    else
        json=""
    fi

    printf '%s\n' "$json" \
        | grep -oE '"data":"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' \
        | sed -E 's/^"data":"//; s/"$//' \
        | sort -u || true
}

# Удаляет все строки /etc/hosts вида "<ip> <host>" для указанного хоста (с любым IP).
dns_remove_hosts_entry() {
    local host="$1"
    [[ -n "$host" && -f /etc/hosts ]] || return 0
    local host_re="${host//./\\.}"
    grep -Eq "^[[:space:]]*[0-9.]+[[:space:]]+${host_re}([[:space:]]|$)" /etc/hosts 2>/dev/null || return 0
    local _tmp
    _tmp=$(mktemp)
    grep -Ev "^[[:space:]]*[0-9.]+[[:space:]]+${host_re}([[:space:]]|$)" /etc/hosts > "$_tmp" 2>/dev/null || true
    cat "$_tmp" > /etc/hosts
    rm -f "$_tmp"
}

dns_update_hosts_entry() {
    local host="$1" ip="$2"
    [[ -n "$host" && -n "$ip" ]] || return 1

    # Нужная запись уже есть — ничего не делаем.
    if grep -Eq "^[[:space:]]*${ip//./\\.}[[:space:]]+${host//./\\.}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
        return 0
    fi

    # Сносим устаревшие записи для этого хоста (с другим IP), чтобы не копить дубли и
    # не маскировать реальный DNS старым адресом, затем дописываем актуальный маппинг.
    dns_remove_hosts_entry "$host"
    printf '%s %s\n' "$ip" "$host" >> /etc/hosts
}

# Сброс локального DNS-кэша (systemd-resolved / nscd), чтобы не получить устаревший
# ответ после смены A-записи домена.
dns_flush_cache() {
    if command_exists resolvectl; then
        resolvectl flush-caches 2>/dev/null || true
    elif command_exists systemd-resolve; then
        systemd-resolve --flush-caches 2>/dev/null || true
    fi
    command_exists nscd && nscd -i hosts 2>/dev/null || true
    return 0
}

# Резолв A-записей через публичные резолверы, минуя локальный кэш: dig @1.1.1.1/@8.8.8.8
# плюс DoH. Полезно после смены IP домена, когда локальный резолвер ещё отдаёт старое.
dns_resolve_ipv4s_public() {
    local host="$1" out="" r
    if command_exists dig; then
        for r in 1.1.1.1 8.8.8.8; do
            out+="$(dig +short A "$host" "@${r}" +time=3 +tries=1 2>/dev/null \
                | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)"$'\n'
        done
    fi
    out+="$(doh_resolve_ipv4s "$host" || true)"$'\n'
    printf '%s\n' "$out" \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
        | sort -u || true
}

port_is_listening() {
    local port="$1"
    ss -H -lntp 2>/dev/null | awk -v port=":${port}" '$4 ~ port { found=1 } END { exit(found ? 0 : 1) }'
}

port_listeners() {
    local port="$1"
    ss -H -lntp 2>/dev/null | awk -v port=":${port}" '$4 ~ port { print }' || true
}

dns_resolv_conf_dump() {
    if [[ -L /etc/resolv.conf ]]; then
        echo "symlink -> $(readlink /etc/resolv.conf 2>/dev/null || echo '(unreadable)')"
    fi
    if [[ -r /etc/resolv.conf ]]; then
        sed 's/^/  /' /etc/resolv.conf
    else
        echo "  (unable to read /etc/resolv.conf)"
    fi
}

dns_internet_check() {
    local host port
    for target in \
        "1.1.1.1:443" \
        "1.0.0.1:443" \
        "8.8.8.8:53" \
        "9.9.9.9:53"
    do
        host="${target%:*}"
        port="${target#*:}"
        if timeout 4 bash -c ":</dev/tcp/${host}/${port}" &>/dev/null; then
            printf '%s' "$target"
            return 0
        fi
    done
    return 1
}

dns_restore_resolv_conf() {
    local backup="/etc/resolv.conf.codex.bak"
    if [[ -e /etc/resolv.conf && ! -e "$backup" ]]; then
        cp -a /etc/resolv.conf "$backup" 2>/dev/null || true
    fi

    if command_exists systemctl && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        systemctl stop systemd-resolved 2>/dev/null || true
    fi

    rm -f /etc/resolv.conf
    cat > /etc/resolv.conf <<'EOF'
# Restored by 3x-ui installer after DNS failure
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 9.9.9.9
options timeout:2 attempts:2 rotate
EOF
    chmod 644 /etc/resolv.conf 2>/dev/null || true
}

dns_diagnostics() {
    local context="$1" domain="$2" expected="${3:-}" found="${4:-}"

    warn "[DEBUG] ${context}: dig +short A ${domain}"
    if command_exists dig; then
        dig +short A "$domain" 2>/dev/null | sed 's/^/[DEBUG]   /' || true
    else
        warn "[DEBUG]   dig is not installed"
    fi
    warn "[DEBUG] ${context}: getent ahosts ${domain}"
    getent ahosts "$domain" 2>/dev/null | sed 's/^/[DEBUG]   /' || true
    warn "[DEBUG] ${context}: public resolvers (1.1.1.1/8.8.8.8 + DoH)"
    dns_resolve_ipv4s_public "$domain" | sed 's/^/[DEBUG]   /' || true
    warn "[DEBUG] ${context}: expected IP: ${expected:-'(not set)'}"
    warn "[DEBUG] ${context}: detected IP: ${found:-'(not found)'}"
    warn "[DEBUG] ${context}: /etc/resolv.conf"
    dns_resolv_conf_dump | sed 's/^/[DEBUG]   /'
}

ensure_dns() {
    local context="${1:-network operation}"
    local domain="${2:-${DNS_CHECK_DOMAIN:-deb.debian.org}}"
    local internet_target resolved

    if ! internet_target=$(dns_internet_check); then
        dns_diagnostics "$context" "$domain" "" ""
        die "${context}: no IP-level internet connectivity is available. Check routing, firewall, and NAT first."
    fi

    resolved=$(dns_resolve_ipv4s "$domain")
    if [[ -n "$resolved" ]]; then
        return 0
    fi

    info "${context}: internet is reachable via IP (${internet_target}), but DNS does not resolve ${domain}. Restoring /etc/resolv.conf..."
    dns_restore_resolv_conf

    resolved=$(dns_resolve_ipv4s "$domain")
    if [[ -n "$resolved" ]]; then
        success "${context}: DNS restored for ${domain} (${resolved})."
        return 0
    fi

    info "${context}: attempting DoH fallback for ${domain}..."
    resolved=$(doh_resolve_ipv4s "$domain")
    if [[ -n "$resolved" ]]; then
        dns_update_hosts_entry "$domain" "$(printf '%s\n' "$resolved" | head -1)" || true
        resolved=$(dns_resolve_ipv4s "$domain")
        if [[ -n "$resolved" ]]; then
            success "${context}: DNS restored through DoH for ${domain} (${resolved})."
            return 0
        fi
    fi

    dns_diagnostics "$context" "$domain" "" "$resolved"
    die "${context}: DNS remains unavailable after restoring /etc/resolv.conf."
}

truthy() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON|y|Y|low|LOW|light|LIGHT|lite|LITE)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

spinner_run() {
    local label="$1"
    shift

    # Если fd 3 не подключён к терминалу, просто запускаем команду без анимации.
    if ! { true >&3; } 2>/dev/null; then
        "$@"
        return $?
    fi

    local frames=('.  ' '.. ' '...') frame_index=0 ticker_pid status

    (
        while :; do
            frame_index=$(((frame_index + 1) % ${#frames[@]}))
            printf '\r\033[K%s %s' "$label" "${frames[$frame_index]}" >&3
            sleep 1
        done
    ) &
    ticker_pid=$!

    printf '\r\033[K%s %s' "$label" "${frames[0]}" >&3
    "$@"
    status=$?

    kill "$ticker_pid" 2>/dev/null || true
    wait "$ticker_pid" 2>/dev/null || true

    if [[ $status -eq 0 ]]; then
        printf '\r\033[K%s %s\n' "$label" "done" >&3
    else
        printf '\r\033[K%s %s\n' "$label" "failed" >&3
    fi

    return "$status"
}

install_packages() {
    ensure_dns "Installing packages" "${DNS_CHECK_DOMAIN:-$(default_dns_check_domain)}"
    if command_exists apt-get; then
        apt-get update -qq || true
        apt-get install -y --no-install-recommends "$@"
    elif command_exists yum; then
        yum install -y "$@"
    else
        die "No supported package manager was found. apt-get or yum is required."
    fi
}

port_listening() {
    local port="$1"
    ss -tlnp 2>/dev/null | grep -q ":${port}"
}

wait_for_tcp_port() {
    local port="$1"
    local timeout="${2:-30}"
    local i

    for i in $(seq 1 "$timeout"); do
        port_listening "$port" && return 0
        sleep 1
    done
    return 1
}

validate_port() {
    local name="$1" port="$2"
    [[ "$port" =~ ^[0-9]+$ ]] || die "${name} must be a number between 1 and 65535; current value: ${port}"
    (( port >= 1 && port <= 65535 )) || die "${name} must be a number between 1 and 65535; current value: ${port}"
}

sql_escape() {
    printf '%s' "${1//\'/\'\'}"
}

# Путь к сертификату/ключу, которые Caddy выпускает для домена (ACME).
# Сначала пробуем детерминированный путь Let's Encrypt, иначе ищем по дереву Caddy.
caddy_cert_file() {
    local le="${CADDY_DATA_DIR}/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/${DOMAIN}/${DOMAIN}.crt"
    if [[ -f "$le" ]]; then
        printf '%s' "$le"
        return 0
    fi
    find "${CADDY_DATA_DIR}" -path "*certificates*/${DOMAIN}/${DOMAIN}.crt" 2>/dev/null | head -1
}

caddy_key_file() {
    local crt
    crt=$(caddy_cert_file)
    [[ -n "$crt" ]] && printf '%s' "${crt%.crt}.key"
}

random_alnum() {
    local length="$1" value=""
    value=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c "$length" || true)
    [[ -n "$value" ]] || die "Failed to generate a random string."
    printf '%s' "$value"
}

# Архитектура для релизов x-ui (соответствует именованию ассетов MHSanaei/3x-ui).
xui_arch() {
    case "$(uname -m)" in
        x86_64|x64|amd64)            printf 'amd64' ;;
        i*86|x86)                    printf '386' ;;
        armv8*|aarch64|arm64)        printf 'arm64' ;;
        armv7*|armv7|arm)            printf 'armv7' ;;
        armv6*)                      printf 'armv6' ;;
        armv5*)                      printf 'armv5' ;;
        s390x)                       printf 's390x' ;;
        *)
            warn "Unknown architecture $(uname -m); falling back to amd64."
            printf 'amd64'
            ;;
    esac
}

random_uuid_v4() {
    local hex
    hex=$(openssl rand -hex 16 || true)
    [[ ${#hex} -eq 32 ]] || die "Failed to generate a client UUID."
    printf '%s-%s-4%s-%s%s-%s' \
        "${hex:0:8}" "${hex:8:4}" "${hex:13:3}" \
        "$(printf '%x' "$(( (0x${hex:16:1} & 0x3) | 0x8 ))")" \
        "${hex:17:3}" "${hex:20:12}"
}

[[ $EUID -ne 0 ]] && die "Run this script as root: sudo bash $0"

export WARP_PROXY_PORT="40000"
export OPERA_PROXY_PORT="40001"
export TOR_PORT="40002"
export XRAY_API_PORT="62789"
export HY2_PORT="${HY2_PORT:-63000}"
# Port hopping для Hysteria2: клиент прыгает по диапазону UDP-портов, а на сервере
# весь диапазон редиректится (NAT REDIRECT) на реальный порт HY2_PORT. Помогает
# против блокировок по одному UDP-порту и троттлинга QUIC.
export HY2_HOP="${HY2_HOP:-true}"
export HY2_HOP_RANGE="${HY2_HOP_RANGE:-63000:63999}"
export OPERA_REGION="${OPERA_REGION:-EU}"
export XUI_DIR="/root"
# Нативная установка x-ui: бинарь в /usr/local/x-ui, БД в /etc/x-ui.
export XUI_NATIVE_DIR="/usr/local/x-ui"
export XUI_DB_DIR="/etc/x-ui"
export XUI_DB="${XUI_DB_DIR}/x-ui.db"
# Caddy сам выпускает и продлевает сертификат; читаем его напрямую из каталога Caddy.
export CADDY_DATA_DIR="/var/lib/caddy"
export VLESS_PORT="${VLESS_PORT:-443}"
export ACME_EMAIL="${ACME_EMAIL:-admin@${DOMAIN}}"
# Trojan-WS спрятан за 443: инбаунд слушает только localhost (ws, без TLS),
# а Caddy по секретному пути проксирует на него. Снаружи 443 держит VLESS Reality
# и «крадёт» реальный TLS на Caddy — отдельный публичный порт не нужен.
# TROJAN_PORT — это внутренний localhost-порт бэкенда.
export TROJAN_PORT="${TROJAN_PORT:-8443}"
export TRAFFIC_RESET="${TRAFFIC_RESET:-monthly}"
export LOGFILE="${XUI_DIR}/3xui-install.log"
export XUI_VERSION="latest"
export LOW_POWER_MODE="${LOW_POWER_MODE:-0}"

if truthy "$LOW_POWER_MODE"; then
    export XUI_ENABLE_FAIL2BAN="${XUI_ENABLE_FAIL2BAN:-false}"
    export XUI_LOG_LEVEL="${XUI_LOG_LEVEL:-warning}"
    export XUI_CPUS_LIMIT="${XUI_CPUS_LIMIT:-0.5}"
else
    export XUI_ENABLE_FAIL2BAN="${XUI_ENABLE_FAIL2BAN:-true}"
    export XUI_LOG_LEVEL="${XUI_LOG_LEVEL:-info}"
    export XUI_CPUS_LIMIT="${XUI_CPUS_LIMIT:-}"
fi

export PANEL_PORT="${PANEL_PORT:-60000}"
export PANEL_USER="${PANEL_USER:-admin}"
export SUB_PORT="${SUB_PORT:-60001}"
export SUB_TITLE="${SUB_TITLE:-}"
export SUB_PATH="${SUB_PATH:-/subs/}"

if [[ -z "${PANEL_PASS:-}" ]]; then
    PANEL_PASS=$(random_alnum 18)
    export PANEL_PASS
fi

if [[ -z "${PANEL_PATH:-}" ]]; then
    PANEL_PATH=$(random_alnum 8 | tr '[:upper:]' '[:lower:]')
fi
# Нормализуем: путь должен начинаться и заканчиваться на /
[[ "$PANEL_PATH" != /* ]]  && PANEL_PATH="/${PANEL_PATH}"
[[ "$PANEL_PATH" != */ ]]  && PANEL_PATH="${PANEL_PATH}/"
export PANEL_PATH

# Нормализуем SUB_PATH аналогично
[[ "$SUB_PATH" != /* ]]    && SUB_PATH="/${SUB_PATH}"
[[ "$SUB_PATH" != */ ]]    && SUB_PATH="${SUB_PATH}/"
export SUB_PATH

# Секретный WS-путь для Trojan-инбаунда (точный путь, без трейлинг-слэша).
if [[ -z "${TROJAN_WS_PATH:-}" ]]; then
    TROJAN_WS_PATH=$(random_alnum 10 | tr '[:upper:]' '[:lower:]')
fi
[[ "$TROJAN_WS_PATH" != /* ]] && TROJAN_WS_PATH="/${TROJAN_WS_PATH}"
TROJAN_WS_PATH="${TROJAN_WS_PATH%/}"
export TROJAN_WS_PATH

for _port_var in \
    HY2_PORT VLESS_PORT TROJAN_PORT PANEL_PORT SUB_PORT
do
    validate_port "$_port_var" "${!_port_var}"
done
unset _port_var

# Проверяем диапазон port hopping (формат start:end, оба порта валидны, start<=end).
if truthy "$HY2_HOP"; then
    [[ "$HY2_HOP_RANGE" =~ ^([0-9]+):([0-9]+)$ ]] \
        || die "HY2_HOP_RANGE must be in start:end format (for example 63000:63999); current value: ${HY2_HOP_RANGE}"
    # Save the matches immediately: validate_port uses its own [[ =~ ]] and would overwrite BASH_REMATCH.
    _hop_start="${BASH_REMATCH[1]}"
    _hop_end="${BASH_REMATCH[2]}"
    validate_port "HY2_HOP_RANGE (start)" "$_hop_start"
    validate_port "HY2_HOP_RANGE (end)"  "$_hop_end"
    (( _hop_start <= _hop_end )) \
        || die "HY2_HOP_RANGE: start is greater than end (${HY2_HOP_RANGE})."
    unset _hop_start _hop_end
fi

if [[ -z "${DOMAIN:-}" ]]; then
    read -rp "Enter the domain for selfsteal (for example, vpn.example.com): " DOMAIN
    [[ -z "$DOMAIN" ]] && die "Domain cannot be empty."
fi
export DOMAIN

# По умолчанию название подписки делаем доменом, если оно не задано явно.
export SUB_TITLE="${SUB_TITLE:-${DOMAIN}}"
