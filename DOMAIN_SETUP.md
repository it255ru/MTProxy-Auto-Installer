# Настройка своего домена для MTProxy

Свой домен — обязательное условие для работы прокси в мобильных сетях (Билайн, МТС и др.).

**Почему:** DPI мобильных операторов проверяет что SNI в TLS ClientHello совпадает с реальной A-записью DNS. Если используется чужой домен (`petrovich.ru`, `browser.yandex.com`) — его A-запись указывает на чужой сервер, DPI видит несоответствие и обрывает хэндшейк.

```
БЕЗ своего домена:
  Клиент → SNI=petrovich.ru → DPI проверяет DNS → 95.142.46.35 ≠ ваш IP → BLOCK

СО своим доменом:
  Клиент → SNI=proxy.example.com → DPI проверяет DNS → ваш IP = ваш IP → OK ✓
```

---

## Требования

- Любой домен (например `glab.com`, `myproxy.net`)
- Доступ к панели управления DNS у регистратора
- VPS уже настроен с работающим `mtproxy_install.sh`

---

## Шаг 1 — A-запись в DNS

В панели управления DNS добавьте запись:

| Тип | Имя | Значение | TTL |
|---|---|---|---|
| A | @ или proxy | IP вашего VPS | 300 |

Примеры для разных регистраторов:

**REG.RU:** Личный кабинет → Домены → DNS → Добавить запись → Тип A

**Namecheap:** Domain List → Advanced DNS → Add New Record → A Record

**Cloudflare:** DNS → Add record → Type A → имя → IP (Proxy status: DNS only, не Proxied)

Проверить что запись прижилась (~5 мин после добавления):

```bash
dig +short proxy.example.com
# Должен вернуть: IP вашего VPS
```

---

## Шаг 2 — Открыть порт 80

Certbot использует порт 80 для проверки владения доменом:

```bash
ufw allow 80/tcp comment "HTTP + LE renewal"
```

---

## Шаг 3 — Выпустить Let's Encrypt сертификат

```bash
apt-get install -y certbot nginx

# Выпустить сертификат (порт 80 должен быть свободен)
certbot certonly --standalone \
    -d proxy.example.com \
    --non-interactive \
    --agree-tos \
    -m you@example.com

# Проверить
ls /etc/letsencrypt/live/proxy.example.com/
```

Сертификат действует 90 дней. Certbot автоматически обновляет его через cron.

---

## Шаг 4 — Настроить nginx заглушку

telemt подключается к `mask_host` как к backend для TCP Splice. nginx отдаёт реальный сайт-заглушку — так сканеры видят легитимный сервер.

```bash
# Создать страницу заглушки
mkdir -p /var/www/html
cat > /var/www/html/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head><title>Welcome</title></head>
<body><h1>Service Unavailable</h1><p>Please try again later.</p></body>
</html>
EOF

# Настроить nginx
cat > /etc/nginx/sites-available/proxy << 'EOF'
server {
    listen 80;
    server_name proxy.example.com;
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    location / {
        root /var/www/html;
        index index.html;
    }
}

server {
    listen 8080;
    server_name proxy.example.com;
    root /var/www/html;
    index index.html;
    location / {
        try_files $uri $uri/ =404;
    }
}
EOF

ln -sf /etc/nginx/sites-available/proxy /etc/nginx/sites-enabled/proxy
rm -f /etc/nginx/sites-enabled/default

nginx -t && systemctl restart nginx
ufw allow 8080/tcp comment "nginx mask backend"

# Проверить
curl -s http://127.0.0.1:8080
```

---

## Шаг 5 — Обновить конфиг telemt

```bash
nano /etc/telemt/telemt.toml
```

Изменить секцию `[general.tls]` и `[censorship]`:

```toml
[general.tls]
domain = "proxy.example.com"   # ← ваш домен

[general.links]
public_host = "ВАШ_IP"         # ← IP сервера

[censorship]
unknown_sni_action = "mask"
tls_domain         = "proxy.example.com"   # ← ваш домен
mask_host          = "127.0.0.1"
mask_port          = 8080
```

Перезапустить:

```bash
rm -rf /etc/telemt/tlsfront/
systemctl restart telemt

# Подождать ~90 секунд (инициализация ME pool)
sleep 90

# Получить новые ссылки
curl -s http://127.0.0.1:9091/v1/users | jq -r '.data[].links.tls[0]'
```

---

## Шаг 6 — Проверить

```bash
# Домен в секрете должен быть ваш
curl -s http://127.0.0.1:9091/v1/users | jq -r '.data[0].links.tls[0]'
# → tg://proxy?server=ВАШ_IP&port=443&secret=ee...hex(proxy.example.com)

# Декодировать домен из секрета
python3 -c "print(bytes.fromhex('hex_часть_в_конце_секрета').decode())"

# TCP Splice — проверить сертификат
echo "Q" | timeout 10 openssl s_client \
    -connect ВАШ_IP:443 \
    -servername proxy.example.com 2>&1 | grep -E "Verify return|CN|issuer"
```

---

## Полный итоговый конфиг telemt.toml

```toml
[general]
use_middle_proxy = true
me2dc_fallback   = true
fast_mode        = true

[general.modes]
classic = false
secure  = false
tls     = true

[general.tls]
domain = "proxy.example.com"

[general.links]
public_host = "ВАШ_IP"

[server]
port            = 443
host            = "0.0.0.0"
api_port        = 9091
api_host        = "127.0.0.1"
metrics_port    = 9090
metrics_whitelist = ["127.0.0.1/32", "::1/128"]
max_connections = 10000

[access.users]
user1 = "сгенерированный_секрет_32_символа"
user2 = "другой_секрет_32_символа"

[censorship]
unknown_sni_action               = "mask"
tls_domain                       = "proxy.example.com"
mask_host                        = "127.0.0.1"
mask_port                        = 8080
mask_shape_hardening             = true
mask_shape_hardening_aggressive_mode = true
mask_shape_bucket_floor_bytes    = 512
mask_shape_bucket_cap_bytes      = 4096
mask_timing_normalization_enabled    = true
mask_timing_normalization_floor_ms   = 180
mask_timing_normalization_ceiling_ms = 320
```

---

## Продление сертификата

Certbot устанавливает автоматическое продление через systemd timer. Проверить:

```bash
systemctl status certbot.timer
certbot renew --dry-run   # тестовый прогон без реального продления
```

При продлении certbot временно занимает порт 80 — убедитесь что он открыт в UFW.

---

## Частые ошибки

### `TLS-front fetch not ready within timeout`

telemt пытается загрузить TLS-профиль домена с самого себя — получается петля. Это нормально при `mask_host = "127.0.0.1"` — telemt использует fallback с fake cert. Прокси работает, но TLS-профиль не кешируется.

Не критично — клиенты подключаются нормально.

### `Telegram handshake timeout` в логах

SNI домена в секрете не совпадает с A-записью DNS. Проверьте:
1. A-запись указывает на IP вашего сервера: `dig +short proxy.example.com`
2. В конфиге telemt указан правильный домен
3. Кеш tlsfront удалён и telemt перезапущен

### После перезапуска telemt порт 443 не открывается сразу

telemt инициализирует соединения с Telegram DC ~80–90 секунд. Подождите и проверьте снова:

```bash
sleep 90 && ss -tlnp | grep 443
```

---

## Совместимость с операторами (проверено)

| Оператор | Результат |
|---|---|
| Ростелеком (WiFi) | ✅ Работает |
| Билайн 4G | ✅ Работает со своим доменом |
| Tele2 (Москва) | ✅ Работает, ~240ms |
