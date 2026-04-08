# MTProxy Auto-Installer

Автоматическая установка официального Telegram MTProxy в Docker.  
Настраивает firewall, запускает прокси и проверяет доступность из России.

> Протестировано на **Debian 13 (trixie)**

---

## Минимальные требования к серверу

| Параметр | Минимум | Рекомендуется |
|----------|---------|---------------|
| CPU | 1 vCPU | 2 vCPU (Hi-CPU) |
| RAM | 512 MB | 1 GB |
| Диск | 5 GB | 10 GB |
| Сеть | 100 Mbps | 1 Gbps |
| ОС | Debian 11+ / Ubuntu 20.04+ | Debian 13 / Ubuntu 22.04 |

**Важно по расположению сервера:**
- ❌ Vultr Stockholm, Vultr Amsterdam — заблокированы большинством российских провайдеров
- ✅ Финляндия, Нидерланды (ufo.hosting), Германия, Франция — обычно доступны из России

---

## Установка

```bash
curl -fsSL https://raw.githubusercontent.com/it255ru/MTProxy-Auto-Installer/main/mtproxy_install.sh | bash
```

Или с указанием порта:

```bash
curl -fsSL https://raw.githubusercontent.com/it255ru/MTProxy-Auto-Installer/main/mtproxy_install.sh -o mtproxy_install.sh
bash mtproxy_install.sh [port] [secret]
```

**Примеры:**

```bash
# Стандартный порт 2443
bash mtproxy_install.sh

# Свой порт
bash mtproxy_install.sh 8443

# Свой порт и секрет (32 hex символа)
bash mtproxy_install.sh 8443 abc123def456abc123def456abc123de
```

---

## Что делает скрипт

1. Определяет ОС и версию
2. Устанавливает curl, python3, openssl, ufw
3. Устанавливает Docker (официальный репозиторий docker.com)
4. Настраивает UFW — открывает SSH и MTProxy порт, блокирует остальное
5. Генерирует секрет и запускает MTProxy в Docker с `--restart always`
6. Проверяет доступность порта из России через check-host.net API
7. Настраивает cron на ежедневное обновление конфига серверов Telegram

---

## Управление

```bash
# Статус
docker ps | grep mtproxy

# Логи
docker logs mtproxy -f

# Перезапуск
docker restart mtproxy

# Остановить
docker stop mtproxy

# Обновить секрет
docker rm -f mtproxy && bash mtproxy_install.sh 2443

# Посмотреть секрет
cat /etc/mtproxy-secret
```

---

## Совместимость

| ОС | Версия | Статус |
|----|--------|--------|
| Debian | 13 (trixie) | ✅ Протестировано |
| Debian | 12 (bookworm) | ✅ Поддерживается |
| Debian | 11 (bullseye) | ✅ Поддерживается |
| Ubuntu | 24.04 LTS | ✅ Поддерживается |
| Ubuntu | 22.04 LTS | ✅ Поддерживается |
| Ubuntu | 20.04 LTS | ✅ Поддерживается |
