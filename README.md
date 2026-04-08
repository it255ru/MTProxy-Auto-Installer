# MTProxy Auto-Installer

Установка и защита MTProxy (telemt) с маскировкой под реальный HTTPS.  
Трафик неотличим от обычного HTTPS — DPI и сканеры ТСПУ получают настоящий сертификат домена-маски.

> Протестировано на **Debian 13 (trixie)**

---

## Скрипты и порядок запуска

Репозиторий содержит 4 скрипта. Запускать в указанном порядке:

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│  ШАГ 1 — На VPS-сервере                                │
│  bash mtproxy_install.sh                                │
│  Устанавливает telemt, генерирует ключи, мониторинг    │
│                                                         │
│  ШАГ 2 — На VPS-сервере                                │
│  bash tspu_server_check.sh                              │
│  Проверяет что прокси виден из России и не детектируем │
│                                                         │
│  ШАГ 3 — На VPS-сервере                                │
│  bash server_harden.sh                                  │
│  Защищает сервер: SSH, fail2ban, автообновления        │
│                                                         │
│  ШАГ 4 — На машине клиента (в России)                  │
│  bash tspu_client_check.sh <ip> <port> <secret>        │
│  Диагностирует подключение через ТСПУ                  │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

| Скрипт | Где запускать | Когда |
|---|---|---|
| `mtproxy_install.sh` | VPS | Первый запуск, при смене IP |
| `tspu_server_check.sh` | VPS | После установки и при подозрении на блокировку |
| `server_harden.sh` | VPS | После проверки прокси, один раз |
| `tspu_client_check.sh` | Клиент (Россия) | При проблемах с подключением |

Подробная документация по каждому скрипту: **[README_INSTALL.md](README_INSTALL.md)**, **[README_CHECKERS.md](README_CHECKERS.md)**, **[README_HARDEN.md](README_HARDEN.md)**

---

## Быстрый старт

### 1. Установить прокси

```bash
bash mtproxy_install.sh
# или с параметрами:
bash mtproxy_install.sh 443 www.bing.com you@example.com
```

Получить ссылки для подключения:
```bash
curl -s http://127.0.0.1:9091/v1/users | jq
```

Результат — ссылка вида:
```
tg://proxy?server=1.2.3.4&port=443&secret=ee47baa7...
```

---

### 2. Проверить сервер из России

```bash
bash tspu_server_check.sh
```

Ключевые результаты:
```
[2] RESULT: NOT BLOCKED — port 443 accessible from Russia ✓
[5] ✓ Real TLS — certificate verified OK (TCP Splice working)
[6] ✓ Max latency drift: +0.0ms — stable
```

Если всё зелёное — прокси работает и не детектируется.

---

### 3. Защитить сервер

> ⚠️ Сначала настройте SSH-ключи — скрипт отключит парольный вход.

```bash
bash server_harden.sh 8443   # укажите ваш SSH-порт
```

Проверить в новом терминале что SSH работает, затем:
```bash
ufw delete allow 22/tcp   # закрыть старый порт
```

---

### 4. Диагностика с клиента (при проблемах)

Запустить на машине в России:

```bash
bash tspu_client_check.sh 1.2.3.4 443 ee47baa7...secret...
```

---

## Почему не официальный Docker-образ Telegram

Официальный `telegrammessenger/proxy` (2020 года) **детектируется ТСПУ** с апреля 2026:

| Проблема | Следствие |
|---|---|
| Уникальный JA3/JA4 fingerprint — порядок cipher suites не совпадает ни с одним браузером | DPI идентифицирует MTProxy за секунды |
| Без секрета возвращает ошибку или обрывает соединение | Сканер ТСПУ фиксирует аномалию |

Наблюдаемый паттерн блокировки: **40ms → 600ms → полный блок за 5–15 часов.**

**telemt** решает это через TCP Splice:

```
Клиент с секретом   →  telemt  →  Telegram MTProxy
Клиент без секрета  →  telemt  →  реальный сайт-маска (bing.com)
ТСПУ сканер         →  получает реальный TLS-сертификат от bing.com
```

| Режим | DPI fingerprint | Время до блокировки |
|---|---|---|
| Plain MTProto | Сигнатура в первых пакетах | Секунды |
| FakeTLS `ee` (официальный Docker) | Уникальный JA3/JA4 | Минуты |
| **telemt TCP Splice** | **Реальный браузерный TLS** | **Часы / дни** |

---

## Как ТСПУ блокирует прокси

```
Новое подключение IP:port
        │
        ▼
Stage 1 (0–15 мин): DPI анализирует сессию
  Распознан → лог → SPFS → ЦСУ
  protocols capacity 2-10%: дроп пакетов
  40ms → 600ms (симптом: задержка растёт)
        │
        ▼
Stage 2 (5–15 мин после Stage 1):
  IP:port → блок-лист → полная блокировка
```

**Что блокируется:** IP:port — не секрет, не содержимое.  
**Смена секрета не помогает.**

При блокировке — действовать в этом порядке:
1. Сменить IP сервера (наиболее эффективно)
2. Сменить домен-маску: `bash mtproxy_install.sh 443 www.apple.com`
3. Сменить порт: `bash mtproxy_install.sh 8443`

---

## Мониторинг прокси

Устанавливается автоматически при `mtproxy_install.sh`.  
Запускается каждые 15 минут, проверяет задержку с российских узлов.

```
< 150 ms   → OK
> 150 ms   → WARN_LATENCY (лог)
> 400 ms   → WARNING + email (Stage 1 ТСПУ)
недоступен → CRITICAL + email (Stage 2, полный блок)
```

```bash
# Запустить вручную
mtproxy-monitor

# Лог
tail -f /var/log/mtproxy-monitor.log

# Настроить email
echo 'you@example.com' > /etc/telemt/notify-email
```

---

## Управление прокси

```bash
# Статус
systemctl status telemt

# Логи
journalctl -u telemt -f

# Все ссылки для подключения
curl -s http://127.0.0.1:9091/v1/users | jq

# Добавить пользователя (без перезапуска)
openssl rand -hex 16   # сгенерировать секрет
# добавить в /etc/telemt/telemt.toml → [access.users]

# Перезапуск
systemctl restart telemt
```

---

## Требования к серверу

| Параметр | Минимум | Рекомендуется |
|----------|---------|---------------|
| CPU | 1 vCPU | 2 vCPU |
| RAM | 512 MB | 1 GB |
| Диск | 5 GB | 10 GB |
| ОС | Debian 11+ / Ubuntu 20.04+ | Debian 13 |

**Выбор хостинга:**
- ❌ Vultr Stockholm, Vultr Amsterdam — AS заблокированы РКН
- ✅ Финляндия, Нидерланды, Германия, Франция

Проверить AS: [bgp.he.net](https://bgp.he.net)

---

## Совместимость

| ОС | install | server_check | harden | client_check |
|----|:-:|:-:|:-:|:-:|
| Debian 13 (trixie) | ✅ | ✅ | ✅ | ✅ |
| Debian 12 (bookworm) | ✅ | ✅ | ✅ | ✅ |
| Debian 11 (bullseye) | ✅ | ✅ | ✅ | ✅ |
| Ubuntu 24.04 LTS | ✅ | ✅ | ✅ | ✅ |
| Ubuntu 22.04 LTS | ✅ | ✅ | ✅ | ✅ |
| Ubuntu 20.04 LTS | ✅ | ✅ | ✅ | ✅ |

Архитектуры: `amd64`, `arm64`, `armv7`
