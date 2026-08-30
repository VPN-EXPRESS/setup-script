# 3x-ui Fast Install Setup

Набор скриптов для автоматического развертывания VPN-инфраструктуры на VPS на базе 3x-ui, Xray, Caddy, Cloudflare WARP, Opera Proxy, Tor и базового сетевого hardening. Проект рассчитан на быстрый запуск личного VPN-сервера без ручной настройки x-ui, подписок, маршрутизации, шлюзов и ACME-сертификатов.

## Что входит в установку

- Нативная установка 3x-ui с systemd-сервисом `x-ui`
- Xray и протоколы VLESS Reality, Hysteria2 и Trojan-WS
- Caddy в режиме selfsteal для получения ACME-сертификатов и маскировки трафика
- Inbound-конфигурации без предсозданных клиентов, готовые для ручного управления через 3x-ui
- Разделение трафика по маршрутам:
  - RU-трафик через WARP
  - выбранные зарубежные сервисы через Opera Proxy
  - `.onion` через Tor
  - всё остальное напрямую
- BBR и базовая защита через fail2ban
- Поддержка резервного копирования и восстановления конфигураций и данных
- Безопасный повторный деплой с автоматическим бэкапом существующей установки

## Основные сценарии использования

- Быстрая установка на чистом VPS с Debian/Ubuntu
- Развертывание с локальной машины через SSH
- Развертывание напрямую на сервере через `install.sh`
- Поддержка повторного восстановления из резервной копии
- Логирование всех этапов установки и диагностики

## Требования

- Debian 12+ или Ubuntu 22.04+
- Root-доступ по SSH
- Домен с A-записью на публичный IP сервера
- Открытые входящие порты:
  - `80/tcp`
  - `443/tcp` (по умолчанию используется VLESS Reality)
  - `63000/udp` (по умолчанию для Hysteria2)
  - при включенном port hopping — диапазон `63000:63999/udp`

## Быстрый старт

Обязательные параметры:

```bash
bash <(curl -sL https://raw.githubusercontent.com/VPN-EXPRESS/setup-script/main/install.sh) \
  --domain your.domain.com \
  --ip 1.2.3.4 \
  --email admin@domain.com
```

Дополнительные параметры авторизации панели:

```bash
bash install.sh \
  --domain vpn.example.com \
  --ip 1.2.3.4 \
  --email admin@example.com \
  --username admin \
  --password StrongPassword
```

Дополнительные опции:

- `-q, --quiet` — сокращенный вывод
- `-v, --verbose` — подробный режим отладки
- `-h, --help` — справка

После завершения установки скрипт выводит:

- URL панели
- логин и пароль
- параметры доступа, сохраненные в `/root/3xui-credentials.txt`

## Способы установки

### 1. Установка прямо на сервере

Если вы уже подключены к VPS по SSH и хотите установить инфраструктуру без локального деплоя:

```bash
ssh root@<IP>
apt-get update && apt-get install -y git
git clone https://github.com/VPN-EXPRESS/setup-script.git
cd setup-script
bash install.sh --domain vpn.example.com --ip 1.2.3.4 --email admin@example.com
```

Пример с нестандартными портами:

```bash
VLESS_PORT=8443 \
HY2_PORT=63001 \
bash install.sh --domain vpn.example.com --ip 1.2.3.4 --email admin@example.com
```

### 2. Деплой с локальной машины через SSH

Минимальный запуск с запросом домена интерактивно:

```bash
bash deploy.sh <IP>
```

Запуск без интерактивного ввода:

```bash
DOMAIN=vpn.example.com bash deploy.sh <IP>
```

Использование SSH-ключа:

```bash
DOMAIN=vpn.example.com bash deploy.sh <IP> -i ~/.ssh/id_rsa
```

С кастомным SSH-портом:

```bash
SSH_PORT=2222 DOMAIN=vpn.example.com bash deploy.sh <IP>
```

С кастомными портами VPN:

```bash
DOMAIN=vpn.example.com \
VLESS_PORT=8443 \
HY2_PORT=63001 \
bash deploy.sh <IP>
```

`deploy.sh` копирует содержимое `steps/` на сервер, запускает `setup.sh` и сохраняет итоговые данные доступа в `/root/3xui-credentials.txt`.

## Архитектура и компоненты

| Компонент        | Описание                                                                                          |
| ------------------------- | --------------------------------------------------------------------------------------------------------- |
| **3x-ui**           | Панель управления Xray и инбаундами с native systemd-сервисом`x-ui` |
| **VLESS Reality**   | Основной входной режим, работает на`443` по умолчанию          |
| **Hysteria2**       | UDP-сервис поверх TLS, работает на`63000/udp` по умолчанию             |
| **Trojan-WS**       | WebSocket + TLS, проксируется через Caddy и скрыт за общим`443`           |
| **Caddy selfsteal** | Выдает ACME-сертификаты и обслуживает fallback/маскировку          |
| **Cloudflare WARP** | Локальный SOCKS5-outbound для RU-ресурсов                                             |
| **Opera Proxy**     | Локальный SOCKS5-outbound для выбранных зарубежных сервисов        |
| **Tor**             | SOCKS5 для`.onion` и других сценариев на основе Tor                          |
| **BBR**             | Ускорение TCP-коннектов для стабильной скорости                    |
| **fail2ban**        | Защита от перебора и простых атак                                             |

## Маршрутизация трафика

| Тип трафика                                  | Направление |
| ------------------------------------------------------ | ---------------------- |
| Реклама и вредоносные домены  | `blocked`            |
| RU-домены`.ru`, `.su`, `.рф` и RU GeoIP | `warp`               |
| `.onion`, `check.torproject.org`                   | `tor`                |
| Disney+, Reddit                                        | `opera`              |
| Всё остальное                              | `direct`             |

GeoIP/GeoSite для подписок и маршрутизации используются из внешних правил и адаптированы под проект.

## После установки

После успешного развёртывания вы получите:

- Панель: `https://<DOMAIN>/<PANEL_PATH>/`
- Логин, пароль и параметры доступа в `/root/3xui-credentials.txt`
- Логи установки в `/root/3xui-install.log`
- Полный журнал в `/root/3xui-install-full.log`
- Данные x-ui в `/etc/x-ui/x-ui.db`
- Бинарники x-ui и Xray в `/usr/local/x-ui/`

## Переменные окружения

Основные параметры можно задавать напрямую перед запуском `install.sh` или `deploy.sh`.

| Переменная | По умолчанию | Описание                                      |
| -------------------- | ----------------------- | ----------------------------------------------------- |
| `DOMAIN`           | —                      | Домен для сертификата и SNI       |
| `PANEL_PORT`       | `60000`               | Локальный порт панели 3x-ui        |
| `PANEL_USER`       | `admin`               | Логин панели                               |
| `PANEL_PASS`       | случайный      | Пароль панели                             |
| `PANEL_PATH`       | случайный      | Путь к панели                              |
| `SUB_PORT`         | `60001`               | Локальный порт подписок          |
| `SUB_PATH`         | `/subs/`              | Путь к подписке 3x-ui                    |
| `SUB_TITLE`        | domain                  | Название подписки 3x-ui               |
| `VLESS_PORT`       | `443`                 | Порт VLESS Reality                                |
| `TROJAN_PORT`      | `8443`                | Локальный адрес Trojan-WS               |
| `TROJAN_WS_PATH`   | случайный      | WS-путь для Caddy                              |
| `HY2_PORT`         | `63000`               | Порт Hysteria2                                    |
| `HY2_HOP`          | `true`                | Включение port hopping                       |
| `HY2_HOP_RANGE`    | `63000:63999`         | Диапазон UDP-портов для hopping      |
| `OPERA_REGION`     | `EU`                  | Регион Opera Proxy                              |
| `TRAFFIC_RESET`    | `monthly`             | Политика сброса трафика          |
| `LOW_POWER_MODE`   | `0`                   | Экономный режим для слабых VPS |
| `SSH_PORT`         | `22`                  | SSH-порт на сервере                      |
| `SSH_USER`         | `root`                | Пользователь SSH                          |

Пример с пользовательскими параметрами:

```bash
DOMAIN=vpn.example.com \
PANEL_PORT=60010 \
PANEL_PASS=MySecretPass \
VLESS_PORT=8443 \
HY2_PORT=63001 \
OPERA_REGION=US \
bash install.sh
```

Экономный режим для слабого VPS:

```bash
LOW_POWER_MODE=1 bash install.sh --domain vpn.example.com --ip 1.2.3.4 --email admin@example.com
```

## Резервное копирование и восстановление

### Создание копии

```bash
bash backup.sh <IP>
```

Со своим SSH-ключом или нестандартным портом:

```bash
bash backup.sh <IP> -i ~/.ssh/id_rsa
SSH_PORT=2222 bash backup.sh <IP>
BACKUP_DIR=~/my-backups bash backup.sh <IP>
```

### Восстановление

```bash
bash restore.sh <IP> backups/backup_1.2.3.4_20260508_120000.tar.gz
bash restore.sh <IP> backups/backup_*.tar.gz -i ~/.ssh/id_rsa
```

> Важно: `restore.sh` предназначен для сервера, на котором уже установлено рабочее окружение (Caddy, Tor, WARP, Opera Proxy и т.д.). На чистом VPS сначала выполняется `deploy.sh`, затем `restore.sh`.

В архив включены:

- база 3x-ui (`/etc/x-ui`)
- сертификаты и ключи
- конфигурации Caddy (`/etc/caddy/Caddyfile`)
- веб-контент (`/var/www/html`)
- данные ACME Caddy (`/var/lib/caddy`)
- файл доступов `/root/3xui-credentials.txt`

### Серверный бэкап и восстановление внутри окружения

Установка также включает серверные скрипты в `steps/`:

```bash
bash /root/3xui-setup/backup.sh
bash /root/3xui-setup/restore.sh latest
bash /root/3xui-setup/restore.sh
```

Архивы сохраняются в `/root/backups/` и могут ротироваться через переменную `KEEP`:

```bash
KEEP=14 bash /root/3xui-setup/backup.sh
```

## Удаление установленного окружения

Для полного удаления компонентов, установленных этим проектом, используйте `uninstall.sh` от имени root. Скрипт останавливает и удаляет 3x-ui/Xray, Caddy, Tor, Cloudflare WARP, Opera Proxy и fail2ban, а также связанные конфигурации, systemd-юниты, бинарные файлы и логи.

По умолчанию перед удалением запрашивается подтверждение:

```bash
sudo bash uninstall.sh
```

Дополнительные режимы:

```bash
sudo bash uninstall.sh --force
sudo bash uninstall.sh --remove-repo
sudo bash uninstall.sh --remove-repo --remove-backups
```

- `--force` — пропустить запрос подтверждения
- `--remove-repo` — удалить копию проекта `/root/3xui-setup`, если она существует
- `--remove-backups` — удалить резервные архивы из `/root/backups`

Скрипт не изменяет и не удаляет системный firewall (`ufw`, `firewalld`, `iptables` или `nftables`), поскольку проект его не устанавливает и не настраивает.

## Структура проекта

```text
├── install.sh          # Установка напрямую на сервере
├── deploy.sh           # Деплой с локальной машины через SSH
├── backup.sh           # Локальный бэкап с удалённого сервера
├── restore.sh          # Восстановление сервера из архива
├── uninstall.sh        # Полное удаление установленного окружения
├── backups/            # Локальные бэкапы (gitignored)
├── scripts/
│   ├── local_lib.sh    # Общие функции локальных скриптов
│   └── remote_backup.sh
├── steps/
│   ├── setup.sh        # Оркестратор установки
│   ├── _lib.sh         # Общие функции и дефолты окружения
│   ├── prereqs.sh      # Подготовка системных зависимостей
│   ├── bbr.sh          # Настройка BBR
│   ├── warp.sh         # Cloudflare WARP
│   ├── opera-proxy.sh  # Opera Proxy
│   ├── tor.sh          # Tor
│   ├── fail2ban.sh     # fail2ban
│   ├── selfsteal.sh    # Caddy selfsteal и ACME
│   ├── xui.sh          # Компоненты 3x-ui, Xray и конфиги
│   ├── backup.sh       # Серверный бэкап
│   └── restore.sh      # Серверное восстановление
├── README.md           # Основная документация проекта
└── install.sh          # Точка входа установки
```

## Поддержка и диагностика

Если установка завершилась с ошибкой, проверьте:

```bash
cat /root/3xui-install-full.log
journalctl -u x-ui -n 100 --no-pager
systemctl status x-ui
systemctl status caddy
```

Если xray падает, панель 3x-ui обычно остаётся доступной на локальном адресе; в таком случае можно восстановить работоспособность через SSH и перезапуск сервиса:

```bash
ssh root@<IP> 'systemctl restart x-ui'
```

Важно: публичный порт `443` принадлежит xray. При сбое xray внешний доступ к `https://<DOMAIN>` временно исчезает, даже если панель x-ui продолжает работать локально.
