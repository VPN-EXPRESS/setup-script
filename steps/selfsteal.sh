# shellcheck source=steps/_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)/_lib.sh"

info "Installing selfsteal (Caddy)..."

# Порт selfsteal-сайта. ДОЛЖЕН совпадать с target/fallback в steps/xui.sh (9443).
SELFSTEAL_PORT="${SELFSTEAL_PORT:-9443}"
CADDYFILE="/etc/caddy/Caddyfile"
WEBROOT="/var/www/html"
# CADDY_DATA_DIR (каталог ACME-данных Caddy) задан в _lib.sh.
# Источник sni-шаблонов сайта-заглушки — ссылка на папку с шаблонами на GitHub.
# Чтобы взять шаблоны из другого места, поменяйте этот URL на ссылку папки вида:
#   https://github.com/<owner>/<repo>/tree/<branch>/<путь-до-папок-с-шаблонами>
SELFSTEAL_TEMPLATES_URL="https://github.com/DigneZzZ/remnawave-scripts/tree/main/sni-templates"

# Разбираем URL на owner/repo, ветку и путь до папки с шаблонами.
_u="${SELFSTEAL_TEMPLATES_URL%/}"
_u="${_u#https://github.com/}"; _u="${_u#http://github.com/}"
[[ "$_u" == */tree/* ]] || die "SELFSTEAL_TEMPLATES_URL must use the format https://github.com/<owner>/<repo>/tree/<branch>/<path>"
TEMPLATES_REPO="${_u%%/tree/*}"
_rest="${_u#*/tree/}"
if [[ "$_rest" == */* ]]; then
    TEMPLATES_BRANCH="${_rest%%/*}"
    TEMPLATES_PATH="${_rest#*/}"
else
    TEMPLATES_BRANCH="$_rest"
    TEMPLATES_PATH=""
fi

# ── Проверка DNS: домен указывает на этот сервер ─────────────────────────────
info "Validating DNS: $DOMAIN -> this server..."
# Снимаем возможную залипшую запись домена из /etc/hosts (её мог дописать ensure_dns
# DoH-fallback'ом при ранних сбоях DNS). Иначе старый IP маскирует реальный DNS: домен
# у нас публичный и должен резолвиться через настоящие резолверы, а не из /etc/hosts.
dns_remove_hosts_entry "$DOMAIN"
ensure_dns "Проверка DNS домена" "$DOMAIN"
# IP этого сервера. На VPS за NAT `ip route ... src` даёт приватный адрес, поэтому
# обязательно добавляем публичный IP с внешних echo-сервисов (именно его видит ACME).
# Собираем ВСЕ кандидаты — без них проверку «домен указывает сюда» делать нельзя.
_server_ips=$(
    {
        printf '%s\n' "${SERVER_IP:-}"
        ip -4 route get 1.1.1.1 2>/dev/null \
            | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }'
        curl -fsSL -4 --connect-timeout 5 --max-time 8 ifconfig.io   2>/dev/null \
            || curl -fsSL -4 --connect-timeout 5 --max-time 8 icanhazip.com 2>/dev/null \
            || curl -fsSL -4 --connect-timeout 5 --max-time 8 api.ipify.org 2>/dev/null \
            || true
        echo
    } | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u
)

# Сбрасываем локальный кэш, иначе после смены A-записи резолвер отдаёт старый IP.
dns_flush_cache
_dns_a_records=$(dig +short A "$DOMAIN" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
_dns_ahosts_raw=$(getent ahosts "$DOMAIN" 2>/dev/null || true)
_dns_ahosts=$(printf '%s\n' "$_dns_ahosts_raw" \
    | awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $1}' \
    | sort -u || true)
# Публичные резолверы (1.1.1.1/8.8.8.8 + DoH) — это то, что увидит ACME снаружи.
# Локальный резолв (dig/getent) — вспомогательный, его используем только если публичный пуст.
_dns_public=$(dns_resolve_ipv4s_public "$DOMAIN")
_dns_local=$(printf '%s\n%s\n' "$_dns_a_records" "$_dns_ahosts" \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u || true)
# Авторитетный для проверки набор — публичный (как видит ACME); локальный лишь как fallback.
_dns_authoritative=$(printf '%s\n' "${_dns_public:-$_dns_local}" | grep -E '^[0-9.]+$' | sort -u || true)
_dns_ip=$(printf '%s\n' "$_dns_authoritative" | head -1)

if [[ -z "$_dns_authoritative" ]]; then
    dns_diagnostics "Проверка DNS домена" "$DOMAIN" "$(printf '%s ' $_server_ips)" "$_dns_ip"
    die "DNS resolution failed for $DOMAIN: neither public nor local resolvers returned an IPv4 address."
fi

if [[ -z "$_server_ips" ]]; then
    dns_diagnostics "Проверка DNS домена" "$DOMAIN" "" "$_dns_ip"
    die "Unable to determine this server's public IP (ip route and external IP services are unavailable); DNS validation cannot continue."
fi

# Домен должен резолвиться хотя бы в один из IP этого сервера (пересечение множеств).
_match=$(comm -12 <(printf '%s\n' "$_server_ips") <(printf '%s\n' "$_dns_authoritative") || true)
if [[ -z "$_match" ]]; then
    dns_diagnostics "Проверка DNS домена" "$DOMAIN" "$(printf '%s ' $_server_ips)" "$_dns_ip"
    die "DNS for $DOMAIN does not point to this server. Server IPs: $(printf '%s ' $_server_ips)| domain resolves to: $(printf '%s ' $_dns_authoritative)"
fi
success "DNS: $DOMAIN -> $(printf '%s\n' "$_match" | head -1) (this server)"

check_port_free() {
    local port="$1"
    local listeners
    if port_is_listening "$port"; then
        listeners=$(port_listeners "$port")
        warn "[DEBUG] Port ${port} is already in use:"
        printf '%s\n' "$listeners" | sed 's/^/[DEBUG]   /'
        die "Port ${port}/tcp is already in use. Free it before installing selfsteal."
    fi
}

# При повторной установке наш же Caddy с прошлого раза держит :80 и SELFSTEAL_PORT,
# из-за чего проверка ниже упала бы. Останавливаем его до проверки — ниже Caddy всё
# равно переконфигурируется и перезапускается. Чужой сервис на :80 (nginx/apache и т.п.)
# проверка по-прежнему поймает и прервёт установку.
if command_exists systemctl && systemctl is-active --quiet caddy 2>/dev/null; then
    info "Stopping the previously running Caddy before port validation (reinstallation)..."
    systemctl stop caddy || true
fi

check_port_free 80
check_port_free "$SELFSTEAL_PORT"

# ── Установка Caddy из официального apt-репозитория ───────────────────────────
install_caddy_native() {
    if command_exists caddy; then
        info "Caddy is already installed ($(caddy version 2>/dev/null | head -1)); skipping installation."
        return 0
    fi
    command_exists apt-get || die "Native Caddy installation is supported only on Debian/Ubuntu (apt)."

    ensure_dns "Installing Caddy" "dl.cloudsmith.io"
    install_packages debian-keyring debian-archive-keyring apt-transport-https curl gnupg \
        || die "Failed to install dependencies for the Caddy repository."

    curl -fsSL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 60 \
        'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
        || die "Failed to retrieve the Caddy repository signing key."
    chmod 644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg

    curl -fsSL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 60 \
        'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        -o /etc/apt/sources.list.d/caddy-stable.list \
        || die "Failed to retrieve the Caddy repository definition."

    apt-get update -qq || die "apt update for Caddy failed."
    apt-get install -y caddy || die "Failed to install Caddy."
    command_exists caddy || die "caddy was not found after installation."
}
install_caddy_native

# ── Сайт-заглушка: случайный шаблон из sni-templates ─────────────────────────
ensure_dns "Downloading selfsteal template" "api.github.com"
ensure_dns "Downloading selfsteal template" "raw.githubusercontent.com"

_tree_json=$(curl -fsSL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 60 \
    "https://api.github.com/repos/${TEMPLATES_REPO}/git/trees/${TEMPLATES_BRANCH}?recursive=1") \
    || die "Failed to retrieve the selfsteal template list."

# Нормализуем путь к папке шаблонов: без ведущего/висячего слэша, затем один трейлинг-слэш.
TEMPLATES_PATH="${TEMPLATES_PATH#/}"; TEMPLATES_PATH="${TEMPLATES_PATH%/}"
_prefix="${TEMPLATES_PATH:+${TEMPLATES_PATH}/}"   # "sni-templates/" или "" для корня репо

# Достаём все пути из дерева (только значения "path") — дальше работаем строками bash.
mapfile -t _all_paths < <(printf '%s' "$_tree_json" \
    | grep -oE '"path": *"[^"]+"' \
    | sed -E 's/^"path": *"//; s/"$//')
[[ ${#_all_paths[@]} -gt 0 ]] || die "Failed to parse the template repository tree."

# Имена шаблонов = директории первого уровня под $_prefix (файлы в корне пропускаем).
declare -A _seen_tpl=()
_templates=()
for _p in "${_all_paths[@]}"; do
    [[ -n "$_prefix" && "$_p" != "$_prefix"* ]] && continue
    _rest="${_p#"$_prefix"}"
    _top="${_rest%%/*}"
    [[ "$_top" == "$_rest" || -z "$_top" ]] && continue   # нет вложенности → не папка-шаблон
    if [[ -z "${_seen_tpl[$_top]:-}" ]]; then
        _seen_tpl["$_top"]=1
        _templates+=("$_top")
    fi
done
[[ ${#_templates[@]} -gt 0 ]] || die "The selfsteal template list is empty (repository: ${TEMPLATES_REPO}, path: ${TEMPLATES_PATH:-<root>})."

_choice="${_templates[RANDOM % ${#_templates[@]}]}"
info "Selected selfsteal template: ${_choice} (${#_templates[@]} available)"

# Файлы выбранного шаблона — только файлы (последний сегмент с расширением).
_files=()
for _p in "${_all_paths[@]}"; do
    [[ "$_p" == "${_prefix}${_choice}/"* ]] || continue
    _last="${_p##*/}"
    [[ "$_last" == *.* ]] || continue
    _files+=("$_p")
done
[[ ${#_files[@]} -gt 0 ]] || die "No files were found in template ${_choice}."

rm -rf "$WEBROOT"
mkdir -p "$WEBROOT"
for _f in "${_files[@]}"; do
    _rel="${_f#"${_prefix}${_choice}/"}"
    _dest="${WEBROOT}/${_rel}"
    mkdir -p "$(dirname "$_dest")"
    curl -fsSL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 120 \
        "https://raw.githubusercontent.com/${TEMPLATES_REPO}/${TEMPLATES_BRANCH}/${_f}" \
        -o "$_dest" \
        || die "Failed to download template file: ${_f}"
done
id caddy &>/dev/null && chown -R caddy:caddy "$WEBROOT" 2>/dev/null || true
success "Selfsteal site deployed to ${WEBROOT} (${#_files[@]} files)."

# Логи идут в stderr → journald (journalctl -u caddy). Файловые логи не используем,
# чтобы избежать проблем с правами (caddy validate под root создаёт файл от root).
cat > "$CADDYFILE" <<CADDY
{
	https_port ${SELFSTEAL_PORT}
	default_bind 127.0.0.1
	servers {
		# Только HTTP/1.1: этот Caddy отдаёт лишь панель/подписку/заглушку, h2 тут
		# ничего не ускоряет, но ломает WebSocket дашборда панели — браузер по h2
		# делает WS через extended CONNECT, и в связке Reality-steal + proxy_protocol
		# апгрейд рвётся. h1 → стандартный WS-upgrade сквозь весь путь.
		protocols h1
		listener_wrappers {
			proxy_protocol {
				allow 127.0.0.1/32
			}
			tls
		}
	}
	auto_https disable_redirects
	admin off
	log {
		output stderr
		level ERROR
	}
}

http://${DOMAIN} {
	bind 0.0.0.0
	redir https://${DOMAIN}{uri} permanent
}

https://${DOMAIN} {
	# Сертификат через ACME. Основной CA — ZeroSSL (мягче к валидации, отдельные лимиты),
	# фолбэк — Let's Encrypt. EAB для ZeroSSL Caddy генерирует сам по email (ключ не нужен).
	# Порядок issuer'ов = порядок попыток; чтобы сделать основным LE — поменяй блоки местами.
	tls {
		issuer acme {
			dir https://acme.zerossl.com/v2/DV90
            email ${ACME_EMAIL}
		}
		issuer acme {
			dir https://acme-v02.api.letsencrypt.org/directory
            email ${ACME_EMAIL}
		}
	}
	# Панель 3x-ui по секретному пути → локальный HTTPS-бэкенд x-ui.
	# x-ui отдаёт HTTPS (web/subCertFile зашиты ради кнопки «взять сертификат панели»),
	# поэтому бэкенд https. tls_insecure_skip_verify — проверка имени/срока на loopback
	# не нужна (публичный TLS даёт сам Caddy), зато нет 502 после продления сертификата.
	# versions 1.1 — ОБЯЗАТЕЛЬНО: WebSocket дашборда панели апгрейдится по HTTP/1.1,
	# а к https-бэкенду Caddy иначе согласует h2 по ALPN и WS-апгрейд ломается.
	@panel path ${PANEL_PATH%/} ${PANEL_PATH}*
	handle @panel {
		reverse_proxy https://127.0.0.1:${PANEL_PORT} {
			# WebSocket дашборда панели: x-ui принимает WS, только если Origin совпадает
			# с его собственным хостом. За прокси Origin = публичный домен → x-ui отдаёт
			# 403. Переписываем Origin на loopback-адрес бэкенда — апгрейд проходит.
			# Роутинг панели по пути (webBasePath), не по Host, так что это безопасно.
			header_up Origin https://127.0.0.1:${PANEL_PORT}
			transport http {
				tls_insecure_skip_verify
				versions 1.1
			}
		}
	}
	# Подписка → локальный HTTPS-бэкенд x-ui
	@sub path ${SUB_PATH%/} ${SUB_PATH}*
	handle @sub {
		reverse_proxy https://127.0.0.1:${SUB_PORT} {
			transport http {
				tls_insecure_skip_verify
				versions 1.1
			}
		}
	}
	# Trojan-WS по секретному пути → localhost-инбаунд x-ui (ws без TLS).
	# Caddy сам апгрейдит WebSocket; TLS здесь уже терминирован Caddy.
	@trojan path ${TROJAN_WS_PATH}
	handle @trojan {
		reverse_proxy 127.0.0.1:${TROJAN_PORT}
	}
	# Всё остальное → сайт-заглушка (selfsteal)
	handle {
		encode gzip
		header {
			-Server
			X-Content-Type-Options "nosniff"
			X-Frame-Options "SAMEORIGIN"
			X-XSS-Protection "1; mode=block"
		}
		root * ${WEBROOT}
		try_files {path} /index.html
		file_server
	}
}

:${SELFSTEAL_PORT} {
	tls internal
	respond 204
	log off
}

:80 {
	bind 0.0.0.0
	respond 204
	log off
}
CADDY

caddy validate --config "$CADDYFILE" >/dev/null 2>&1 \
    || die "Caddyfile validation failed (the Caddy build may lack the proxy_protocol listener wrapper). Check: caddy validate --config ${CADDYFILE}"

# ── Запуск Caddy ─────────────────────────────────────────────────────────────
systemctl enable caddy >/dev/null 2>&1 || true
systemctl restart caddy || die "Failed to start the Caddy service."

caddy_runtime_diagnostics() {
    warn "[DEBUG] systemctl status caddy"
    systemctl --no-pager status caddy 2>&1 | sed 's/^/[DEBUG]   /' | tail -n 20 || true
    warn "[DEBUG] ss -lntp | grep ':80\\|:${SELFSTEAL_PORT}'"
    ss -lntp 2>/dev/null | grep -E ":(80|${SELFSTEAL_PORT})\b" | sed 's/^/[DEBUG]   /' || true
}

info "Waiting for Caddy to issue the certificate (up to 180 seconds)..."
CERT_SRC=""; KEY_SRC=""
for i in $(seq 1 180); do
    CERT_SRC=$(find "$CADDY_DATA_DIR" -path "*certificates*/${DOMAIN}/${DOMAIN}.crt" 2>/dev/null | head -1 || true)
    if [[ -n "$CERT_SRC" ]]; then
        KEY_SRC="${CERT_SRC%.crt}.key"
        [[ -f "$KEY_SRC" ]] && break
    fi
    CERT_SRC=""
    sleep 1
done

if [[ -z "$CERT_SRC" || ! -f "$KEY_SRC" ]]; then
    _caddy_logs=$(journalctl -u caddy --no-pager -n 150 2>/dev/null || true)
    warn "Errors from the Caddy log:"
    echo "$_caddy_logs" | grep -iE '"level":"error"|error|fail' | sed 's/^/  /' | tail -n 30 || true
    if echo "$_caddy_logs" | grep -qiE "rateLimited|too many.*authorizations|retry after"; then
        _retry=$(echo "$_caddy_logs" | grep -oP 'retry after \K[0-9]{4}-[0-9-]+ [0-9:]+ UTC' | tail -1 || true)
        die "Rate limit reached for $DOMAIN.${_retry:+ Retry after: $_retry (UTC).} Options: wait or use another subdomain."
    elif echo "$_caddy_logs" | grep -qiE "connection refused|i/o timeout|dial tcp.*:80|timeout during connect"; then
        die "Port 80/tcp is not reachable externally. Check whether the provider is blocking it."
    elif echo "$_caddy_logs" | grep -qiE "no such host|NXDOMAIN|SERVFAIL"; then
        die "DNS for $DOMAIN is not resolving externally (DNS IP: $_dns_ip). Check the A record and DNS propagation."
    else
        caddy_runtime_diagnostics
        die "Caddy did not obtain a certificate within 180 seconds. DNS: $DOMAIN -> $_dns_ip."
    fi
fi

# Сертификат не копируем: Hysteria2 (xray) читает его напрямую из каталога Caddy,
# а Caddy сам продлевает его на месте. Чистим старый cron-синк, если остался.
(crontab -l 2>/dev/null | grep -v "caddy-cert-sync" || true) | crontab - 2>/dev/null || true
rm -f /root/caddy-cert-sync.sh 2>/dev/null || true

success "Selfsteal (Caddy) installed. Certificate: ${CERT_SRC}"
