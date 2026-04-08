# MTProxy Auto-Installer

Автоматическая установка **telemt** — MTProxy с TCP Splice маскировкой.  
Трафик неотличим от обычного HTTPS: DPI и сканеры получают реальный сертификат домена-маски.

> Протестировано на **Debian 13 (trixie)**

---

## Почему не официальный Docker-образ Telegram

Официальный `telegrammessenger/proxy` (2020 года) **детектируется ТСПУ** по двум причинам:

| Проблема | Следствие |
|---|---|
| Уникальный JA3/JA4 fingerprint — порядок cipher suites не совпадает ни с одним браузером | DPI идентифицирует MTProxy за секунды |
| Без секрета возвращает ошибку или обрывает соединение | Сканер ТСПУ фиксирует аномалию |

Наблюдаемый паттерн блокировки: **40–50ms → 600ms → полный блок за 5–15 часов.**

**telemt** решает это через TCP Splice:

```
Клиент с секретом   →  telemt  →  Telegram MTProxy
Клиент без секрета  →  telemt  →  реальный сайт-маска (bing.com / microsoft.com / ...)
ТСПУ сканер         →  получает реальный TLS-сертификат, реальный ответ от сайта-маски
```

DPI видит легитимный HTTPS. JA3/JA4 fingerprint — настоящий. Цепочка доверия сертификата — настоящая.

---

## Скрипты репозитория

| Скрипт | Назначение |
|---|---|
| `mtproxy_install.sh` | Установка telemt на VPS |
| `tspu_server_check.sh` | Диагностика сервера: видимость из России, TCP Splice, деградация ТСПУ |
| `tspu_client_check.sh` | Диагностика с клиента: подключение через ТСПУ, jitter, traceroute |

---

## Минимальные требования к серверу

| Параметр | Минимум | Рекомендуется |
|----------|---------|---------------|
| CPU | 1 vCPU | 2 vCPU |
| RAM | 512 MB | 1 GB |
| Диск | 5 GB | 10 GB |
| Сеть | 100 Mbps | 1 Gbps |
| ОС | Debian 11+ / Ubuntu 20.04+ | Debian 13 / Ubuntu 22.04 |

**По выбору хостинга:**
- ❌ Vultr Stockholm (`70.34.0.0/15`), Vultr Amsterdam (`78.141.192.0/18`) — AS заблокированы РКН
- ✅ Финляндия, Нидерланды, Германия, Франция — обычно доступны из России

Проверить AS своего сервера: [bgp.he.net](https://bgp.he.net) — если AS уже в блокировках, смена порта и настроек не поможет.

---

## Установка

```bash
curl -fsSL https://raw.githubusercontent.com/it265ru/MTProxy-Auto-Installer/main/mtproxy_install.sh | bash
```

Или скачать и запустить вручную:

```bash
curl -fsSL https://raw.githubusercontent.com/it255ru/MTProxy-Auto-Installer/refs/heads/main/mtproxy_install.sh -o mtproxy_install.sh
bash mtproxy_install.sh [port] [mask_domain] [email]
```

**Параметры:**

| Параметр | По умолчанию | Описание |
|---|---|---|
| `port` | `443` | Порт прокси. 443 — имитирует HTTPS |
| `mask_domain` | `www.bing.com` | Домен-маска для TCP Splice |
| `email` | — | Email для алертов мониторинга |

**Примеры:**

```bash
# Стандартный запуск (порт 443, маска bing.com)
bash mtproxy_install.sh

# Другой домен-маска
bash mtproxy_install.sh 443 www.microsoft.com

# С алертами на почту
bash mtproxy_install.sh 443 www.bing.com you@example.com

# Альтернативный порт (если 443 занят)
bash mtproxy_install.sh 8443 www.apple.com
```

---

## Что делает скрипт

1. Определяет ОС и архитектуру (`amd64` / `arm64` / `armv7`)
2. Устанавливает зависимости: curl, python3, openssl, ufw, jq
3. Скачивает последний релиз **telemt** с GitHub (авто-выбор правильного бинарника)
4. Устанавливает telemt как **systemd-сервис** с автозапуском
5. Генерирует секреты для двух пользователей (`user1`, `user2`)
6. Записывает конфиг `/etc/telemt/telemt.toml` с режимом TCP Splice
7. Настраивает UFW — SSH и MTProxy порт
8. Верифицирует TCP Splice: `openssl s_client` должен получить настоящий сертификат домена-маски
9. Устанавливает **мониторинг** (cron каждые 15 мин): замеряет задержку с российских узлов

---

## Ссылки для подключения

После установки ссылки доступны через API:

```bash
curl -s http://127.0.0.1:9091/v1/users | jq
```

Добавить пользователей в `/etc/telemt/telemt.toml`:

```toml
[access.users]
user1 = "сгенерированный_секрет_32_символа"
user2 = "другой_секрет"
# новый секрет: openssl rand -hex 16
```

Перезапуск не нужен — telemt подхватывает изменения на лету.

---

## Управление

```bash
# Статус сервиса
systemctl status telemt

# Логи в реальном времени
journalctl -u telemt -f

# Перезапуск
systemctl restart telemt

# Все ссылки для подключения
curl -s http://127.0.0.1:9091/v1/users | jq

# Добавить пользователя (без перезапуска)
# → добавить строку в /etc/telemt/telemt.toml → [access.users]
openssl rand -hex 16   # сгенерировать новый секрет

# Сменить домен-маску
bash mtproxy_install.sh 443 www.apple.com
```

---

## Мониторинг

Скрипт устанавливает мониторинг, который каждые **15 минут** проверяет задержку с российских узлов и обнаруживает деградацию ТСПУ **до** полной блокировки.

```
< 150 ms   → OK — норма
> 150 ms   → WARN_LATENCY — повышенная, только в лог
> 400 ms   → WARNING + email — Stage 1 ТСПУ: дроп пакетов
недоступен → CRITICAL + email — Stage 2: IP:port в блок-листе ЦСУ
```

```bash
# Запустить проверку вручную
mtproxy-monitor

# Смотреть лог мониторинга
tail -f /var/log/mtproxy-monitor.log

# Настроить email-алерты
echo 'you@example.com' > /etc/telemt/notify-email
```

---

## Диагностика

### tspu_server_check.sh — запускать на VPS

```bash
bash tspu_server_check.sh [port]
```

| Шаг | Что проверяет |
|---|---|
| 1 | Geo, ISP, `hosting` флаг IP |
| 2 | Порт из России через check-host.net |
| 3 | Локальные открытые порты |
| 4 | Процесс telemt / xray / sing-box |
| 5 | **TCP Splice**: без секрета сканер должен получить реальный сертификат домена-маски |
| 6 | **Тест деградации 25 сек**: измеряет drift задержки — ранний признак ТСПУ Stage 1 |
| 7 | DNS разрешение с сервера |
| 8 | BBR, memory, swap, сетевые ошибки |
| 9 | IP-репутация, AS в блок-листах |

Пример корректного вывода (всё работает):

```
[2] RESULT: NOT BLOCKED — port 443 accessible from Russia ✓
[5] ✓ Real TLS — certificate verified OK (TCP Splice working)
    CN (issuer): GlobalSign
    Verify return code: 0 (ok)
[6] ✓ Connection held 25.3s without forced drop
    ✓ Max latency drift: +0.0ms — stable
[8] ✓ BBR enabled
    ✓ Fair queue (fq) enabled
```

---

### tspu_client_check.sh — запускать на машине пользователя

```bash
bash tspu_client_check.sh <server_ip> <port> [secret]

# MTProxy с секретом
bash tspu_client_check.sh 1.2.3.4 443 ee47baa7...secret...

# Без секрета (общая диагностика)
bash tspu_client_check.sh 1.2.3.4 443
```

| Симптом | Шаг для диагностики |
|---|---|
| Telegram не подключается | 2 — TCP timeout |
| Отваливается через ~20 сек | 3 — drop_time 14–24с |
| Медленно, задержки | 3 — latency drift, 8 — jitter |
| `wsarecv: forcibly closed` | 3 — ТСПУ 19s signature |
| `dns: exchange failed` | 6 — DNS заблокирован |
| Видео заикается | 8 — jitter > 50ms |
| Секрет не принимается | 5 — формат секрета |

---

## Как ТСПУ блокирует прокси

```
Новое подключение IP:port
        │
        ▼
Stage 1 (0–15 мин): DPI анализирует сессию
  Размеры пакетов, частота, паттерны, сигнатуры
        │
        ├─ Не распознан → трафик идёт свободно ✓
        └─ Распознан → лог → SPFS → ЦСУ
                │
                │ protocols capacity: 2–10% дроп пакетов
                │ TCP retransmit → задержка растёт (40ms → 600ms)
                ▼
Stage 2 (5–15 мин после Stage 1):
  IP:port → в блок-лист фильтра (behavior: block)
  IP:port → Eco Highway BGP
        └─ Полная блокировка
```

**Что блокируется:** IP:port — не секрет, не содержимое. Смена секрета не помогает.

| Режим | DPI fingerprint | Время до Stage 1 |
|---|---|---|
| Plain MTProto | Сигнатура в первых пакетах | Секунды |
| DD-обфускация | Статистический паттерн | Минуты |
| FakeTLS `ee` (официальный Docker) | Уникальный JA3/JA4 | Минуты |
| **telemt TCP Splice** | **Реальный браузерный TLS** | **Часы / дни** |

---

## Что делать при блокировке

1. **Latency alert (>400ms)** — подождать следующую проверку через 15 мин, возможно временное
2. **Полная блокировка** — сменить IP сервера (наиболее эффективно)
3. **Альтернатива** — сменить домен-маску: `bash mtproxy_install.sh 443 www.apple.com`
4. **Крайний случай** — сменить порт: `bash mtproxy_install.sh 8443`

❌ **Смена секрета не помогает** — ТСПУ блокирует IP:port, не содержимое.

---

## Известные проблемы и решения

### Скрипт не находит бинарник telemt

Ручная установка для `x86_64`:

```bash
curl -L -o /tmp/telemt.tar.gz \
  https://github.com/telemt/telemt/releases/latest/download/telemt-x86_64-linux-gnu.tar.gz
tar -xzf /tmp/telemt.tar.gz -C /tmp/
mv /tmp/telemt /usr/local/bin/telemt
chmod +x /usr/local/bin/telemt
bash mtproxy_install.sh
```

---

### Прокси заблокирован сразу после установки

IP уже в блок-листе ЦСУ. Нужен новый IP — пересоздать VPS или взять дополнительный адрес.

---

### Прокси не работает на новом сервере

Проверить AS: [bgp.he.net](https://bgp.he.net). Если AS заблокирован РКН целиком — смена настроек не поможет, нужен другой хостер.

---

### Звонки в Telegram через MTProxy не работают

Telegram не поддерживает звонки через MTProxy — только через SOCKS5. Техническое ограничение протокола.

---

## Спонсорский канал (@MTProxybot)

```toml
# /etc/telemt/telemt.toml
[general]
ad_tag = "тег_от_бота"
use_middle_proxy = true
```

```bash
# 1. @MTProxybot → /newproxy → IP:PORT
# 2. Отправить секрет: curl -s http://127.0.0.1:9091/v1/users | jq '.[0].links.tls[0]'
# 3. Скопировать тег → вставить в telemt.toml → systemctl restart telemt
# 4. @MTProxybot → /myproxies → Set promotion → публичная ссылка канала
```

> Спонсорский канал не отображается у тех, кто уже на него подписан.

---

## Рекомендуемые домены-маски

| Домен | Почему подходит |
|---|---|
| `www.bing.com` | Microsoft, высокий трафик, стабильный TLS |
| `www.microsoft.com` | Никогда не блокируется в РФ |
| `www.apple.com` | Высокая репутация, CDN |
| `www.amazon.com` | AWS CDN, огромный трафик |
| `cdn.cloudflare.com` | CDN, стандартный TLS fingerprint |
| `ajax.googleapis.com` | Google CDN, всегда доступен |

> Собственные домены (.ru / .com) не рекомендуются — малый трафик создаёт аномалию для DPI.

---

## Совместимость

| ОС | Версия | install | server_check | client_check |
|----|--------|:-:|:-:|:-:|
| Debian | 13 (trixie) | ✅ Протестировано | ✅ | ✅ |
| Debian | 12 (bookworm) | ✅ | ✅ | ✅ |
| Debian | 11 (bullseye) | ✅ | ✅ | ✅ |
| Ubuntu | 24.04 LTS | ✅ | ✅ | ✅ |
| Ubuntu | 22.04 LTS | ✅ | ✅ | ✅ |
| Ubuntu | 20.04 LTS | ✅ | ✅ | ✅ |

Архитектуры: `amd64` (x86_64), `arm64` (aarch64), `armv7`
