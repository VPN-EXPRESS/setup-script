## Требования

- Ubuntu/Debian сервер
- Root доступ
- Домен с A-записью, указывающей на IP сервера

## Быстрый старт ( пока не работает из-за приватности репозитория )

### Удаленная установка через curl

```bash
bash <(curl -sL https://raw.githubusercontent.com/VPN-EXPRESS/setup-script/main/install.sh) \
  --domain your.domain.com \
  --ip 1.2.3.4 \
  --email admin@domain.com
```

### Локальная установка

```bash
git clone https://github.com/VPN-EXPRESS/setup-script.git
cd setup
sudo bash install.sh --domain your.domain.com --ip 1.2.3.4 --email admin@domain.com
```

## Параметры CLI

### Обязательные параметры

| Параметр | Описание | Пример |
|----------|----------|--------|
| `--domain` | Доменное имя сервера | `vpn.example.com` |
| `--ip` | IP адрес сервера | `1.2.3.4` |
| `--email` | Email для Let's Encrypt | `admin@example.com` |

### Опциональные параметры

| Параметр | По умолчанию | Описание |
|----------|--------------|----------|
| `--username` | `admin` | Имя пользователя админки |
| `--password` | `admin` | Пароль админки |

### Дополнительные флаги

| Флаг | Описание |
|------|----------|
| `-h, --help` | Показать справку |
| `-q, --quiet` | Тихий режим (только ошибки) |
| `-v, --verbose` | Подробный вывод (debug) |

## Структура проекта

```
setup/
├── install.sh          # Главный скрипт запуска
├── README.md           # Документация
└── lib/
    ├── colors.sh       # Цвета и иконки
    ├── logger.sh       # Функции логирования
    ├── cli.sh          # Парсинг аргументов
    ├── validators.sh   # Валидация параметров
    ├── system.sh       # Системные функции
    ├── ssl.sh          # Работа с SSL сертификатами
    ├── nginx.sh        # Конфигурация Nginx
    └── panel.sh        # Установка 3X-UI
```

## Что делает скрипт

1. Обновляет системные пакеты
2. Устанавливает зависимости (curl, socat, nginx, cron)
3. Проверяет DNS резолвинг домена
4. Устанавливает acme.sh для SSL сертификатов
5. Устанавливает 3X-UI панель
6. Получает SSL сертификат Let's Encrypt
7. Настраивает Nginx как reverse proxy
8. Запускает все сервисы
9. Создает инбаунд hysteria2
10. Выводит информацию для доступа
