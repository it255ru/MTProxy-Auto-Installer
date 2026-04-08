# Server Hardening

Скрипт полного security hardening для VPS с MTProxy (telemt).  
Защищает сервер от брутфорса, сканирования и несанкционированного доступа.

> Протестировано на **Debian 13 (trixie)**

---

## Что делает скрипт

| Шаг | Что настраивает |
|---|---|
| 1 | Устанавливает пакеты: fail2ban, unattended-upgrades, logwatch, auditd |
| 2 | **SSH hardening**: только ключи, современная криптография |
| 3 | **UFW**: закрывает всё лишнее, rate limiting на порт 443 |
| 4 | **fail2ban**: защита SSH + обнаружение сканеров прокси |
| 5 | **Автообновления**: security patches без перезагрузки |
| 6 | **Kernel (sysctl)**: anti-spoofing, SYN cookies, ASLR, BBR |
| 7 | **Stealth прокси**: лимит соединений от одного IP на порт 443 |
| 8 | **Аудит**: мониторинг изменений критических файлов |

---

## Требования перед запуском

**Обязательно:** настроить SSH-ключи до запуска скрипта.  
Скрипт отключает парольную аутентификацию. Без ключа вы потеряете доступ к серверу.

### Создать SSH-ключ (Windows)

```powershell
ssh-keygen -t ed25519 -C "mtproxy-server"
```

### Скопировать ключ на сервер

```bash
# На сервере (пока ещё с паролем):
mkdir -p ~/.ssh && chmod 700 ~/.ssh

# В PowerShell — посмотреть публичный ключ:
type C:\Users\USERNAME\.ssh\id_ed25519.pub

# На сервере — вставить содержимое:
echo "ssh-ed25519 AAAA...ваш_ключ..." >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

### Проверить вход по ключу

```powershell
# Открыть НОВЫЙ терминал — должен подключиться БЕЗ пароля:
ssh -p ТЕКУЩИЙ_ПОРТ root@ВАШ_IP
```

Только после успешного входа по ключу — запускать скрипт.

---

## Установка

```bash
curl -fsSL https://raw.githubusercontent.com/it255ru/MTProxy-Auto-Installer/refs/heads/main/server_harden.sh -o server_harden.sh
bash server_harden.sh [новый_ssh_порт]
```

**Параметры:**

| Параметр | По умолчанию | Описание |
|---|---|---|
| `новый_ssh_порт` | `2222` | Порт для SSH. Передайте текущий порт если хотите оставить его |

**Примеры:**

```bash
# Оставить SSH на текущем порту 8443
bash server_harden.sh 8443

# Переехать SSH с 22 на 2222
bash server_harden.sh 2222

# Переехать SSH на свой порт
bash server_harden.sh 55022
```

---

## Процедура безопасного запуска

```
1. Запустить скрипт в текущем терминале
        ↓
2. НЕ ЗАКРЫВАТЬ текущую сессию
        ↓
3. Открыть НОВЫЙ терминал → проверить SSH на новом порту
        ↓
4. Успешно подключились → удалить старый порт из UFW
        ↓
5. Готово
```

```bash
# Шаг 4 — удалить старый порт (только после подтверждения нового):
ufw delete allow 22/tcp
ufw status
```

---

## Что настраивается детально

### SSH hardening

```
Port              → новый (не 22)
PermitRootLogin   → prohibit-password (ключи) или no
PasswordAuth      → no
MaxAuthTries      → 3
LoginGraceTime    → 30 сек
KexAlgorithms     → curve25519-sha256
Ciphers           → chacha20-poly1305, aes256-gcm, aes128-gcm
MACs              → hmac-sha2-256-etm, hmac-sha2-512-etm
```

### fail2ban jails

| Jail | Защита от | Порог | Бан |
|---|---|---|---|
| `sshd` | Брутфорс SSH | 3 попытки за 10 мин | 24 часа |
| `proxy-scan` | Сканирование порта 443 | 20 соединений за 1 мин | 1 час |

### Kernel (sysctl)

```
rp_filter          = 1    # Anti-IP spoofing
tcp_syncookies     = 1    # SYN flood protection
accept_source_route= 0    # Запрет source routing
tcp_congestion     = bbr  # BBR (уже был включён)
randomize_va_space = 2    # ASLR: полная рандомизация
kptr_restrict      = 2    # Скрытие kernel pointers
dmesg_restrict     = 1    # dmesg только для root
sysrq              = 0    # Magic SysRq отключён
```

### Stealth прокси

```
iptables connlimit: max 20 одновременных соединений с одного IP на порт 443
Исключение: 127.0.0.0/8 (localhost) — мониторинг работает без ограничений
```

Это дополняет встроенную защиту telemt:
- Без секрета → реальный сертификат `www.bing.com` (TCP Splice)
- DPI/сканеры видят легитимный HTTPS, а не MTProxy

### auditd — что отслеживается

| Файл / путь | Событие |
|---|---|
| `/etc/passwd`, `/etc/shadow` | Изменение пользователей |
| `/etc/sudoers` | Изменение прав sudo |
| `/etc/ssh/sshd_config` | Изменение конфига SSH |
| `/etc/telemt/` | Изменение конфига прокси |
| `setuid` syscall | Попытки эскалации привилегий |

---

## После установки — мониторинг

### fail2ban

```bash
# Общий статус
fail2ban-client status

# Заблокированные IP (SSH)
fail2ban-client status sshd

# Заблокированные IP (сканеры прокси)
fail2ban-client status proxy-scan

# Разблокировать IP вручную
fail2ban-client set sshd unbanip 1.2.3.4
```

### Логи (Debian 12/13 — journald, не файлы)

```bash
# SSH подключения
journalctl -u ssh -f

# UFW события (заблокированные пакеты)
journalctl -k | grep UFW | tail -20

# Все предупреждения за сегодня
journalctl -p warning --since today

# SSH + sudo события
journalctl | grep -E 'sshd|sudo' | tail -20

# Аудит изменений файлов
ausearch -k identity | tail -20
ausearch -k sudoers | tail -20
ausearch -k sshd_config | tail -20
ausearch -k telemt_config | tail -20
```

### Автообновления

```bash
# Проверить что обновится (без применения)
unattended-upgrade --dry-run

# Применить вручную
unattended-upgrade -v

# Статус сервиса
systemctl status unattended-upgrades
```

### UFW

```bash
ufw status
# После kernel update — требуется ручная перезагрузка:
# reboot
```

---

## Известные особенности

### `/var/log/auth.log` и `/var/log/ufw.log` отсутствуют

На Debian 12/13 логи хранятся в systemd journal, а не в файлах.  
Используйте `journalctl` как показано выше.

### После перезагрузки iptables правила восстанавливаются

Скрипт устанавливает systemd-сервис `iptables-restore` который автоматически применяет правила из `/etc/iptables/rules.v4` при старте.

```bash
# Проверить правила после перезагрузки
iptables -L INPUT -n | grep 443
```

### auditd показывает служебные записи `op=remove_rule` / `op=add_rule`

Это нормально — auditd логирует загрузку собственных правил при старте. Не инциденты.

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
