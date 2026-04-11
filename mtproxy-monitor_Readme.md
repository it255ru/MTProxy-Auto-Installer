# mtproxy-monitor

Автоматический мониторинг MTProxy (telemt) — обнаруживает деградацию ТСПУ **до** полной блокировки.

Запускается cron каждые 15 минут, проверяет задержку с российских узлов и отправляет email-алерт при аномалиях.

---

## Как работает

```
Каждые 15 минут:
    1. systemctl is-active telemt     → сервис жив?
    2. API 127.0.0.1:9091/v1/users    → telemt отвечает?
    3. TCP connect 127.0.0.1:443      → порт слушает?
    4. check-host.net (3 узла в РФ)   → задержка из России?
           ↓
    Записать в лог → отправить email если порог превышен
```

**Почему 15 минут:** окно между ТСПУ Stage 1 (деградация) и Stage 2 (полный блок) — 5–15 минут. Мониторинг даёт время заметить проблему и сменить IP до полной блокировки.

---

## Пороги и статусы

| Задержка | Статус | Действие |
|---|---|---|
| < 150ms | `OK` | Пишет в лог |
| 150–400ms | `WARN_LATENCY` | Пишет в лог, email не отправляет |
| > 400ms | `WARNING` | Пишет в лог + **email** — ТСПУ Stage 1 |
| Недоступен | `CRITICAL` | Пишет в лог + **email** — ТСПУ Stage 2 |
| Сервис упал | `CRITICAL` | Пишет в лог + **email** |

---

## Установка

Устанавливается автоматически при запуске `mtproxy_install.sh`. 

Ручная установка:
```bash
# Скрипт
curl -fsSL https://raw.githubusercontent.com/it265ru/MTProxy-Auto-Installer/main/mtproxy-monitor \
    -o /usr/local/bin/mtproxy-monitor
chmod +x /usr/local/bin/mtproxy-monitor

# Cron
cat > /etc/cron.d/mtproxy-monitor << 'EOF'
*/15 * * * * root /usr/local/bin/mtproxy-monitor >> /var/log/mtproxy-monitor.log 2>&1
EOF

# Ротация логов
cat > /etc/logrotate.d/mtproxy-monitor << 'EOF'
/var/log/mtproxy-monitor.log {
    daily
    rotate 30
    compress
    missingok
    notifempty
}
EOF
```

---

## Настройка

Конфигурация через файлы в `/etc/telemt/`:

```bash
# Email для алертов (обязательно для уведомлений)
echo 'you@example.com' > /etc/telemt/notify-email

# Порог WARNING (ms, по умолчанию 400)
echo '400' > /etc/telemt/latency-crit

# Порог WARN_LATENCY (ms, по умолчанию 150)
echo '150' > /etc/telemt/latency-warn
```

Для отправки email нужен настроенный MTA на сервере:
```bash
apt-get install -y mailutils
# или
apt-get install -y msmtp msmtp-mta
```

---

## Использование

```bash
# Запустить вручную
mtproxy-monitor

# Смотреть лог в реальном времени
tail -f /var/log/mtproxy-monitor.log

# Последние 20 записей
tail -20 /var/log/mtproxy-monitor.log

# Текущий статус
cat /var/run/mtproxy-monitor.status
```

---

## Пример вывода

**Нормальная работа:**
```
[2026-04-11 12:45:01] [INFO] === Monitor check started ===
[2026-04-11 12:45:01] [INFO] Service: active
[2026-04-11 12:45:02] [INFO] API: ok
[2026-04-11 12:45:02] [INFO] Local TCP: 0.1ms
[2026-04-11 12:45:02] [INFO] Checking from Russian nodes (~15 sec)...
[2026-04-11 12:45:17] [INFO]   ru1: 122.4ms
[2026-04-11 12:45:17] [INFO]   ru2: 112.6ms
[2026-04-11 12:45:17] [INFO]   ru3: 115.3ms
[2026-04-11 12:45:17] [INFO] STATUS: OK — avg latency from Russia: 116.8ms
[2026-04-11 12:45:17] [INFO] === Check complete ===
```

**ТСПУ Stage 1 — деградация:**
```
[2026-04-11 13:00:01] [INFO]   ru1: 487ms  ← HIGH (ТСПУ degradation?)
[2026-04-11 13:00:01] [INFO]   ru2: 521ms  ← HIGH (ТСПУ degradation?)
[2026-04-11 13:00:01] [WARN] STATUS: WARNING — latency 504ms (ТСПУ Stage 1 degradation)
```
→ Email отправлен. Пора менять IP или домен.

**ТСПУ Stage 2 — полный блок:**
```
[2026-04-11 13:15:01] [INFO]   ru1: BLOCKED (timeout)
[2026-04-11 13:15:01] [INFO]   ru2: BLOCKED (timeout)
[2026-04-11 13:15:01] [INFO]   ru3: BLOCKED (timeout)
[2026-04-11 13:15:01] [CRIT] STATUS: CRITICAL — fully blocked from Russia
```
→ IP:port в блок-листе ЦСУ. Нужен новый IP.

---

## Email-алерты

### WARNING — деградация (Stage 1)
```
Subject: [MTProxy] WARNING: Latency 504ms — ТСПУ degradation signal

MTProxy 103.35.x.x:443 — HIGH LATENCY from Russia.
Average: 504ms (threshold: 400ms)

With telemt TCP Splice this is unusual. Possible causes:
  a) General VPS routing degradation
  b) ТСПУ Stage 1 beginning

Full block may follow in 5-15 min. Monitor next check.
```

### CRITICAL — полный блок (Stage 2)
```
Subject: [MTProxy] CRITICAL: Fully blocked from Russia

MTProxy 103.35.x.x:443 unreachable from all Russian nodes.
IP:port is in ТСПУ blocklist (Stage 2 complete).

Actions:
  1. Change VPS IP — most effective
  2. Change mask domain: bash /root/mtproxy_install.sh 443 www.apple.com
  3. Change port: bash /root/mtproxy_install.sh 8443
```

---

## Отличие от proxy-stats

| | `mtproxy-monitor` | `proxy-stats` |
|---|---|---|
| Запуск | Автоматически (cron) | Вручную |
| Назначение | Алерты о блокировке | Диагностика подключений |
| Проверяет | Доступность из России | Активных пользователей и ошибки |
| Email | ✅ При аномалиях | ❌ |
| Лог | `/var/log/mtproxy-monitor.log` | Только вывод в терминал |

---

## Требования

| Компонент | Требование |
|---|---|
| Python | 3.6+ |
| systemctl | systemd |
| telemt API | `http://127.0.0.1:9091/v1/users` |
| mail | Опционально (только для email-алертов) |
| check-host.net | Внешний доступ с сервера |
