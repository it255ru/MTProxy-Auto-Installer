#!/bin/bash
# ============================================================
# MTProxy Auto-Installer v3.0 — telemt (TCP Splice)
# Uses telemt instead of official Telegram Docker image.
#
# WHY telemt:
#   Official telegrammessenger/proxy with ee-prefix (FakeTLS) is
#   detectable since April 2026 via JA3/JA4 fingerprint + ECH.
#   telemt uses TCP Splice: clients WITHOUT the secret key get
#   a real TLS connection to the mask host (real cert, real
#   handshake, real response). DPI scanners see legitimate HTTPS.
#
# Usage: bash mtproxy_install.sh [port] [mask_domain] [email]
#   port        — listening port (default: 443)
#   mask_domain — domain to splice to (default: www.bing.com)
#   email       — alert email (optional)
#
# Supports: Ubuntu 20/22/24, Debian 11/12/13
# Run as root.
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

PORT="${1:-443}"
MASK_DOMAIN="${2:-www.bing.com}"
NOTIFY_EMAIL="${3:-${MTPROXY_EMAIL:-}}"

# Latency thresholds (ms) from Russia — based on observed 40→600→block pattern
LATENCY_WARN_MS=150
LATENCY_CRIT_MS=400

# Good mask domains — must be reachable from VPS on 443, real TLS.
# Ideally: high-traffic sites that ISPs never block.
GOOD_MASK_DOMAINS=(
    "www.bing.com"
    "www.microsoft.com"
    "www.apple.com"
    "www.amazon.com"
    "cdn.cloudflare.com"
    "ajax.googleapis.com"
)

TELEMT_CONFIG_DIR="/etc/telemt"
TELEMT_CONFIG="$TELEMT_CONFIG_DIR/telemt.toml"
TELEMT_BIN="/usr/local/bin/telemt"
TELEMT_RELEASE_URL="https://api.github.com/repos/telemt/telemt/releases/latest"

# ============================================================
# ROOT CHECK
# ============================================================
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Run as root: sudo bash $0${NC}"
    exit 1
fi

echo ""
echo "============================================================"
echo " MTProxy Auto-Installer v3.0 — telemt TCP Splice"
echo "============================================================"
echo " Port        : $PORT"
echo " Mask Domain : $MASK_DOMAIN"
echo " Mode        : TLS splice (DPI-proof — real cert + handshake)"
echo " Date        : $(date '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================================"
echo ""

# ============================================================
# STEP 1: DETECT OS
# ============================================================
echo -e "${BLUE}[1/9] Detecting OS...${NC}"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
    echo "  OS  : $PRETTY_NAME"
    echo "  Arch: $ARCH"
else
    echo -e "${RED}Cannot detect OS${NC}"; exit 1
fi
case $OS in
    ubuntu|debian) echo -e "  ${GREEN}✓ Supported OS${NC}" ;;
    *) echo -e "${YELLOW}⚠ Untested: $OS — proceeding${NC}" ;;
esac
echo ""

# ============================================================
# STEP 2: GET SERVER IP
# ============================================================
echo -e "${BLUE}[2/9] Getting server IP...${NC}"
command -v curl &>/dev/null || {
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl
}

SERVER_IP=""
for URL in ifconfig.me api.ipify.org icanhazip.com; do
    SERVER_IP=$(curl -s --max-time 5 "$URL" 2>/dev/null | tr -d '[:space:]')
    [[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
    SERVER_IP=""
done
[ -z "$SERVER_IP" ] && { echo -e "${RED}Cannot determine server IP${NC}"; exit 1; }
echo -e "  ${GREEN}✓ $SERVER_IP${NC}"

GEO=$(curl -s --max-time 5 "http://ip-api.com/json/${SERVER_IP}?fields=country,isp,as" 2>/dev/null)
python3 - "$GEO" << 'EOF' 2>/dev/null
import sys, json
try:
    d = json.loads(sys.argv[1])
    print(f"  Country: {d.get('country','?')}")
    print(f"  ISP    : {d.get('isp','?')}")
    print(f"  AS     : {d.get('as','?')}")
except: pass
EOF
echo ""

# ============================================================
# STEP 3: CHECK PORT & MASK DOMAIN
# ============================================================
echo -e "${BLUE}[3/9] Pre-flight checks...${NC}"

# Port check
PORT_IN_USE=$(ss -tlnp 2>/dev/null | grep ":${PORT} " | grep -oP 'users:\(\("\K[^"]+' | head -1)
if [ -n "$PORT_IN_USE" ] && [ "$PORT_IN_USE" != "telemt" ]; then
    echo -e "  ${YELLOW}⚠ Port ${PORT} used by: ${PORT_IN_USE}${NC}"
    read -p "  Stop $PORT_IN_USE and continue? [y/N]: " ANSWER
    if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
        systemctl stop "$PORT_IN_USE" 2>/dev/null
        systemctl disable "$PORT_IN_USE" 2>/dev/null
        echo -e "  ${GREEN}✓ Stopped $PORT_IN_USE${NC}"
    else
        echo -e "${RED}Re-run with different port: bash $0 8443${NC}"; exit 1
    fi
else
    echo -e "  ${GREEN}✓ Port ${PORT} is free${NC}"
fi

# Validate mask domain
echo "  Checking mask domain reachability: $MASK_DOMAIN"
if curl -s --max-time 8 -o /dev/null -w "%{http_code}" \
        "https://${MASK_DOMAIN}/" 2>/dev/null | grep -q "^[23]"; then
    echo -e "  ${GREEN}✓ $MASK_DOMAIN is reachable (TLS works)${NC}"
else
    echo -e "  ${YELLOW}⚠ $MASK_DOMAIN may be slow or unreachable from this VPS${NC}"
    echo "    telemt will still work — mask domain only needs to be reachable"
    echo "    Alternative: bash $0 $PORT www.microsoft.com"
fi
echo ""

# ============================================================
# STEP 4: INSTALL DEPENDENCIES
# ============================================================
echo -e "${BLUE}[4/9] Installing dependencies...${NC}"
apt-get update -qq 2>/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    curl wget ca-certificates gnupg lsb-release \
    ufw python3 openssl jq mailutils tar 2>/dev/null
echo -e "  ${GREEN}✓ Done${NC}"
echo ""

# ============================================================
# STEP 5: DOWNLOAD & INSTALL TELEMT
# ============================================================
echo -e "${BLUE}[5/9] Installing telemt...${NC}"

# Map arch to telemt release naming
case "$ARCH" in
    amd64|x86_64)   TELEMT_ARCH="amd64" ;;
    arm64|aarch64)  TELEMT_ARCH="arm64" ;;
    armv7l|armhf)   TELEMT_ARCH="armv7" ;;
    *)
        echo -e "${YELLOW}  Unknown arch $ARCH — trying amd64${NC}"
        TELEMT_ARCH="amd64"
        ;;
esac

echo "  Fetching latest telemt release info..."
RELEASE_JSON=$(curl -s --max-time 15 "$TELEMT_RELEASE_URL" 2>/dev/null)
TELEMT_VERSION=$(echo "$RELEASE_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tag_name',''))" 2>/dev/null)

if [ -z "$TELEMT_VERSION" ]; then
    echo -e "${RED}  Cannot fetch telemt release info from GitHub${NC}"
    echo "  Check: https://github.com/telemt/telemt/releases"
    echo "  Manual install: download binary, place at /usr/local/bin/telemt, chmod +x"
    exit 1
fi
echo "  Latest version: $TELEMT_VERSION"

# Find the right asset URL
DOWNLOAD_URL=$(echo "$RELEASE_JSON" | python3 - "$TELEMT_ARCH" << 'EOF'
import sys, json
arch = sys.argv[1]
try:
    data = json.load(sys.stdin)
    assets = data.get('assets', [])
    for a in assets:
        name = a.get('name', '').lower()
        if arch in name and 'linux' in name and name.endswith(('.tar.gz', '.gz', '')):
            print(a['browser_download_url'])
            break
    # fallback — any linux binary
    for a in assets:
        name = a.get('name', '').lower()
        if 'linux' in name and arch in name:
            print(a['browser_download_url'])
            break
except Exception as e:
    pass
EOF
)

if [ -z "$DOWNLOAD_URL" ]; then
    echo -e "${RED}  Cannot find telemt binary for linux/$TELEMT_ARCH${NC}"
    echo "  Available assets:"
    echo "$RELEASE_JSON" | python3 -c \
        "import sys,json; [print('   ', a['name']) for a in json.load(sys.stdin).get('assets',[])]" 2>/dev/null
    echo ""
    echo "  Manual install steps:"
    echo "    1. Download the right binary from https://github.com/telemt/telemt/releases"
    echo "    2. Place it at /usr/local/bin/telemt"
    echo "    3. chmod +x /usr/local/bin/telemt"
    echo "    4. Re-run this script"
    exit 1
fi

echo "  Downloading: $DOWNLOAD_URL"
TMP_FILE="/tmp/telemt_download"
curl -L --max-time 60 -o "$TMP_FILE" "$DOWNLOAD_URL" 2>/dev/null

if [ $? -ne 0 ] || [ ! -s "$TMP_FILE" ]; then
    echo -e "${RED}  Download failed${NC}"; exit 1
fi

# Install binary (handle .tar.gz or direct binary)
if file "$TMP_FILE" 2>/dev/null | grep -q "gzip\|tar"; then
    tar -xzf "$TMP_FILE" -C /tmp/ 2>/dev/null
    EXTRACTED=$(find /tmp -maxdepth 2 -name "telemt" -type f 2>/dev/null | head -1)
    if [ -n "$EXTRACTED" ]; then
        mv "$EXTRACTED" "$TELEMT_BIN"
    else
        echo -e "${RED}  Cannot find telemt binary in archive${NC}"; exit 1
    fi
else
    mv "$TMP_FILE" "$TELEMT_BIN"
fi

chmod +x "$TELEMT_BIN"
rm -f "$TMP_FILE" 2>/dev/null

if "$TELEMT_BIN" --version 2>/dev/null | grep -q "telemt\|version" || [ -x "$TELEMT_BIN" ]; then
    echo -e "  ${GREEN}✓ telemt installed: $TELEMT_VERSION${NC}"
else
    echo -e "${RED}  telemt binary not working — check manually: $TELEMT_BIN --version${NC}"
    exit 1
fi
echo ""

# ============================================================
# STEP 6: FIREWALL
# ============================================================
echo -e "${BLUE}[6/9] Configuring firewall (UFW)...${NC}"
ufw default allow outgoing 2>/dev/null
ufw default deny incoming 2>/dev/null
SSH_PORT=$(ss -tlnp | grep sshd | grep -oP ':\K[0-9]+' | head -1)
SSH_PORT="${SSH_PORT:-22}"
ufw allow "$SSH_PORT/tcp" comment "SSH" 2>/dev/null
ufw allow "$PORT/tcp"     comment "MTProxy telemt TLS" 2>/dev/null
ufw status | grep -q "Status: active" && ufw reload 2>/dev/null || ufw --force enable 2>/dev/null
echo -e "  ${GREEN}✓ SSH=$SSH_PORT MTProxy=$PORT${NC}"
echo ""

# ============================================================
# STEP 7: GENERATE SECRETS & WRITE CONFIG
# ============================================================
echo -e "${BLUE}[7/9] Generating secrets and writing config...${NC}"
echo ""

# Generate secrets for default users
SECRET_USER1=$(openssl rand -hex 16)
SECRET_USER2=$(openssl rand -hex 16)

# Save for reference
mkdir -p "$TELEMT_CONFIG_DIR"
cat > "$TELEMT_CONFIG_DIR/users.txt" << USERS
# telemt user secrets — generated $(date '+%Y-%m-%d %H:%M:%S UTC')
# Format for Telegram: tg://proxy?server=IP&port=PORT&secret=ee<SECRET><DOMAIN_HEX>
# Use the full link from: curl -s http://127.0.0.1:9091/v1/users | jq
user1 = $SECRET_USER1
user2 = $SECRET_USER2
USERS
chmod 600 "$TELEMT_CONFIG_DIR/users.txt"

# Save info for monitoring
echo "$PORT"        > /etc/telemt/port
echo "$SERVER_IP"   > /etc/telemt/server-ip
echo "$MASK_DOMAIN" > /etc/telemt/mask-domain

# Write telemt.toml
cat > "$TELEMT_CONFIG" << TOML
# ============================================================
# telemt configuration — generated $(date '+%Y-%m-%d %H:%M:%S UTC')
# Docs: https://github.com/telemt/telemt
# ============================================================

[general]
# use_middle_proxy = true allows ad sponsorship via @MTProxybot
# Set to false if you want to use Shadowsocks upstream instead
use_middle_proxy = true

[general.modes]
# classic = false  — obsolete, detectable
# secure  = false  — dd-prefix, also detectable
# tls     = true   — TCP Splice mode: real cert + real handshake to mask host
classic = false
secure  = false
tls     = true

[general.tls]
# The domain that unrecognized connections are spliced to.
# DPI scanners and crawlers get a REAL TLS response from this domain:
#   - real certificate chain
#   - real TLS handshake
#   - real HTTP response
# This is NOT FakeTLS — telemt connects to the actual host.
domain = "$MASK_DOMAIN"

[server]
# Port to listen on (use 443 to look like HTTPS)
port    = $PORT
# Bind to all interfaces
host    = "0.0.0.0"

# Management API — used by monitoring script and /v1/users endpoint
# Keep this localhost-only
api_port = 9091
api_host = "127.0.0.1"

# Metrics endpoint (optional, localhost only by default)
metrics_port      = 9090
metrics_whitelist = ["127.0.0.1/32", "::1/128"]

# Maximum concurrent connections (0 = unlimited)
max_connections = 10000

[access.users]
# Each user has their own 32-char hex secret.
# Full connection link (with ee-prefix + domain) is in:
#   curl -s http://127.0.0.1:9091/v1/users | jq
#
# Add more users: openssl rand -hex 16
# No restart needed after adding users.
user1 = "$SECRET_USER1"
user2 = "$SECRET_USER2"

# Optionally limit unique IPs per user:
# [access.user_max_unique_ips]
# user1 = 3   # max 3 devices per link

# Optionally set per-user ad tags (for @MTProxybot sponsorship):
# [access.user_ad_tags]
# user1 = "your_ad_tag_here"

[censorship]
# If a client connects with an SNI that doesn't match our domain,
# splice them to the mask host anyway (don't return an error).
# This prevents "Unknown TLS SNI" errors during domain transitions.
unknown_sni_action = "mask"
TOML

chmod 600 "$TELEMT_CONFIG"

echo -e "  ${MAGENTA}Config:${NC}"
echo "  Mask domain : $MASK_DOMAIN"
echo "  User1 secret: $SECRET_USER1"
echo "  User2 secret: $SECRET_USER2"
echo "  Config file : $TELEMT_CONFIG"
echo "  (Full tg:// links available after start via API)"
echo ""

# ============================================================
# CREATE SYSTEMD SERVICE
# ============================================================
cat > /etc/systemd/system/telemt.service << SERVICE
[Unit]
Description=telemt MTProxy (TCP Splice TLS)
After=network.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$TELEMT_BIN --config $TELEMT_CONFIG
Restart=always
RestartSec=5
LimitNOFILE=65536

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=$TELEMT_CONFIG_DIR /var/log

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable telemt 2>/dev/null
systemctl restart telemt
sleep 4

if systemctl is-active --quiet telemt; then
    echo -e "  ${GREEN}✓ telemt service running${NC}"
else
    echo -e "${RED}  telemt failed to start${NC}"
    echo "  Logs: journalctl -u telemt -n 30"
    journalctl -u telemt -n 20 --no-pager 2>/dev/null | sed 's/^/  /'
    exit 1
fi
echo ""

# ============================================================
# STEP 8: INSTALL MONITORING
# ============================================================
echo -e "${BLUE}[8/9] Installing monitoring...${NC}"
echo ""

# Write email/thresholds to config dir
echo "${NOTIFY_EMAIL:-}" > /etc/telemt/notify-email
echo "$LATENCY_WARN_MS"  > /etc/telemt/latency-warn
echo "$LATENCY_CRIT_MS"  > /etc/telemt/latency-crit

cat > /usr/local/bin/mtproxy-monitor << 'PYEOF'
#!/usr/bin/env python3
"""
MTProxy Monitor (telemt) — detects ТСПУ degradation before full block.

ТСПУ two-stage blocking (from ТСПУ architecture docs):
  Stage 1: DPI detects protocol → logs sent to ЦСУ
           'protocols capacity' drops packets → TCP retransmits → LATENCY RISES
  Stage 2: IP:port added to cleaned blocklist → hard block
  Window between stages: 5-15 minutes.

With telemt TCP Splice, DPI scanners see a real TLS session to the mask host.
Stage 1 detection is much harder. But IP-based blocking (Stage 2 via Eco Highway)
still applies once the ЦСУ accumulates enough logs.

We detect early by measuring latency from Russian nodes every 15 minutes.
"""

import json, time, sys, os, socket, datetime, subprocess
import urllib.request, urllib.error

def read_cfg(f, default=''):
    try: return open(f).read().strip()
    except: return default

SERVER_IP        = read_cfg('/etc/telemt/server-ip')
PORT             = int(read_cfg('/etc/telemt/port', '443'))
MASK_DOMAIN      = read_cfg('/etc/telemt/mask-domain', 'www.bing.com')
LOG_FILE         = '/var/log/mtproxy-monitor.log'
STATUS_FILE      = '/var/run/mtproxy-monitor.status'
NOTIFY_EMAIL     = read_cfg('/etc/telemt/notify-email')
LATENCY_WARN_MS  = int(read_cfg('/etc/telemt/latency-warn', '150'))
LATENCY_CRIT_MS  = int(read_cfg('/etc/telemt/latency-crit', '400'))

RU_NODES = [
    'ru1.node.check-host.net',
    'ru2.node.check-host.net',
    'ru3.node.check-host.net',
    'msk.node.check-host.net',
]

def ts():
    return datetime.datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S')

def log(msg, level='INFO'):
    line = f"[{ts()}] [{level}] {msg}"
    print(line)
    try:
        with open(LOG_FILE, 'a') as f: f.write(line + '\n')
    except: pass

def get_last_status():
    try: return open(STATUS_FILE).read().strip()
    except: return 'UNKNOWN'

def save_status(s):
    try:
        with open(STATUS_FILE, 'w') as f: f.write(s)
    except: pass

def send_alert(subject, body):
    if not NOTIFY_EMAIL: return
    try:
        subprocess.run(['mail', '-s', subject, NOTIFY_EMAIL],
                       input=body, text=True, timeout=15)
        log(f"Alert sent to {NOTIFY_EMAIL}: {subject}")
    except Exception as e:
        log(f"Alert send failed: {e}", 'WARN')

def check_service():
    """Check telemt systemd service status."""
    try:
        r = subprocess.run(['systemctl', 'is-active', 'telemt'],
                           capture_output=True, text=True, timeout=5)
        active = r.stdout.strip() == 'active'
        return active, r.stdout.strip()
    except:
        return False, 'error'

def check_local_port():
    try:
        s = socket.socket()
        s.settimeout(5)
        t = time.time()
        s.connect((SERVER_IP, PORT))
        ms = round((time.time()-t)*1000, 1)
        s.close()
        return True, ms
    except Exception as e:
        return False, str(e)

def check_api():
    """Check telemt management API — get active connections count."""
    try:
        req = urllib.request.Request('http://127.0.0.1:9091/v1/users',
                                     headers={'Accept': 'application/json'})
        with urllib.request.urlopen(req, timeout=5) as r:
            data = json.loads(r.read())
        return True, data
    except:
        return False, None

def check_from_russia():
    """Measure latency from Russian check-host.net nodes."""
    url = f"https://check-host.net/check-tcp?host={SERVER_IP}:{PORT}"
    for n in RU_NODES: url += f"&node={n}"
    try:
        req = urllib.request.Request(url, headers={'Accept': 'application/json'})
        with urllib.request.urlopen(req, timeout=10) as r:
            data = json.loads(r.read())
        req_id = data.get('request_id', '')
    except Exception as e:
        log(f"check-host.net request failed: {e}", 'WARN')
        return []
    if not req_id: return []
    time.sleep(12)
    try:
        req2 = urllib.request.Request(
            f"https://check-host.net/check-result/{req_id}",
            headers={'Accept': 'application/json'})
        with urllib.request.urlopen(req2, timeout=10) as r:
            results = json.loads(r.read())
    except Exception as e:
        log(f"check-host.net result failed: {e}", 'WARN')
        return []
    out = []
    for node, val in results.items():
        short = node.replace('.node.check-host.net', '')
        if val is None:
            out.append((short, None, 'pending'))
        elif isinstance(val, list) and val:
            v = val[0]
            if isinstance(v, dict) and 'time' in v:
                out.append((short, True, round(v['time']*1000, 1)))
            elif isinstance(v, list) and v[0] == 'OK':
                ms = round(v[1]*1000, 1) if len(v) > 1 else 0
                out.append((short, True, ms))
            else:
                err = v[0] if isinstance(v, list) else str(v)
                out.append((short, False, err))
        else:
            out.append((short, False, 'no response'))
    return out

# ---- Main ----
log("=== Monitor check started ===")
last = get_last_status()

# 1. Service running?
svc_ok, svc_st = check_service()
if not svc_ok:
    log(f"SERVICE DOWN: {svc_st}", 'CRIT')
    if last != 'CRIT':
        send_alert(
            "[MTProxy] CRITICAL: telemt service not running",
            f"Server: {SERVER_IP}:{PORT}\nStatus: {svc_st}\n\n"
            f"Fix: systemctl restart telemt\n"
            f"Logs: journalctl -u telemt -n 50"
        )
    save_status('CRIT'); sys.exit(2)
log(f"Service: {svc_st}")

# 2. Management API
api_ok, api_data = check_api()
if api_ok:
    log(f"API: ok ({type(api_data).__name__})")
else:
    log("API: not responding (may be starting up)", 'WARN')

# 3. Local TCP port
local_ok, local_ms = check_local_port()
if not local_ok:
    log(f"LOCAL PORT FAILED: {local_ms}", 'CRIT')
    if last != 'CRIT':
        send_alert(
            "[MTProxy] CRITICAL: Port not responding",
            f"Port {PORT} on {SERVER_IP} not responding.\nError: {local_ms}\n\n"
            f"Fix: systemctl restart telemt"
        )
    save_status('CRIT'); sys.exit(2)
log(f"Local TCP: {local_ms}ms")

# 4. Latency from Russia
log("Checking from Russian nodes (~15 sec)...")
ru = check_from_russia()
ok_nodes   = [(n, ms) for n, s, ms in ru if s is True]
fail_nodes = [(n, ms) for n, s, ms in ru if s is False]
crit_lat   = [(n, ms) for n, ms in ok_nodes if isinstance(ms, float) and ms > LATENCY_CRIT_MS]
warn_lat   = [(n, ms) for n, ms in ok_nodes if isinstance(ms, float) and ms > LATENCY_WARN_MS]

for node, status, ms in ru:
    if status is True:
        flag = ''
        if isinstance(ms, float):
            if ms > LATENCY_CRIT_MS:   flag = ' ← HIGH (ТСПУ degradation?)'
            elif ms > LATENCY_WARN_MS: flag = ' ← elevated'
        log(f"  {node}: {ms}ms{flag}")
    elif status is False:
        log(f"  {node}: BLOCKED ({ms})", 'WARN')
    else:
        log(f"  {node}: {ms}")

# ---- Status ----
if fail_nodes and len(fail_nodes) == len(ru) and ru:
    status = 'CRIT'
    log("STATUS: CRITICAL — fully blocked from Russia", 'CRIT')
    if last != 'CRIT':
        send_alert(
            "[MTProxy] CRITICAL: Fully blocked from Russia",
            f"MTProxy {SERVER_IP}:{PORT} unreachable from all Russian nodes.\n\n"
            f"IP:port is in ТСПУ blocklist (Stage 2).\n\n"
            f"Results:\n" + "\n".join(f"  {n}: {m}" for n,m in fail_nodes) +
            f"\n\nActions (in order of effectiveness):\n"
            f"  1. Change VPS IP — most effective\n"
            f"  2. Change mask domain: bash /root/mtproxy_install.sh {PORT} www.apple.com\n"
            f"  3. Change port: bash /root/mtproxy_install.sh 8443\n\n"
            f"Service is still running — only external IP:port is blocked."
        )

elif crit_lat:
    status = 'WARN'
    avg_ms = round(sum(ms for _,ms in crit_lat)/len(crit_lat), 1)
    log(f"STATUS: WARNING — latency {avg_ms}ms (ТСПУ Stage 1 degradation possible)", 'WARN')
    if last not in ('WARN', 'CRIT'):
        send_alert(
            f"[MTProxy] WARNING: Latency {avg_ms}ms — ТСПУ degradation signal",
            f"MTProxy {SERVER_IP}:{PORT} — HIGH LATENCY from Russia.\n\n"
            f"Average: {avg_ms}ms  (critical threshold: {LATENCY_CRIT_MS}ms)\n\n"
            f"Nodes:\n" + "\n".join(f"  {n}: {ms}ms" for n,ms in crit_lat) +
            f"\n\nWith telemt TCP Splice this is unusual — it may indicate:\n"
            f"  a) General routing degradation to your VPS\n"
            f"  b) ТСПУ Stage 1 beginning (IP:port recognition)\n\n"
            f"Full block (Stage 2) may follow in 5-15 minutes.\n"
            f"Monitor the next check in 15 minutes."
        )

elif fail_nodes and ok_nodes:
    status = 'WARN'
    log("STATUS: WARNING — partial block (ISP-level)", 'WARN')
    if last not in ('WARN', 'CRIT'):
        send_alert(
            "[MTProxy] WARNING: Partial block from Russia",
            f"Reachable: {', '.join(n for n,_ in ok_nodes)}\n"
            f"Blocked:   {', '.join(n for n,_ in fail_nodes)}\n\n"
            f"May be ISP-level block or routing issue."
        )

elif warn_lat:
    avg_ms = round(sum(ms for _,ms in warn_lat)/len(warn_lat), 1)
    status = 'WARN_LATENCY'
    log(f"STATUS: ELEVATED LATENCY — avg {avg_ms}ms (watching)")

else:
    status = 'OK'
    avg_ms = round(sum(ms for _,ms in ok_nodes)/len(ok_nodes), 1) if ok_nodes else 0
    log(f"STATUS: OK — avg latency from Russia: {avg_ms}ms")
    if last in ('WARN', 'CRIT'):
        send_alert(
            "[MTProxy] RECOVERED: Proxy accessible from Russia",
            f"MTProxy {SERVER_IP}:{PORT} is reachable again.\nPrevious status: {last}"
        )

save_status(status)
log("=== Check complete ===\n")
sys.exit(0 if status in ('OK','WARN_LATENCY') else (1 if status=='WARN' else 2))
PYEOF

chmod +x /usr/local/bin/mtproxy-monitor

# Email config
if [ -n "$NOTIFY_EMAIL" ]; then
    echo "$NOTIFY_EMAIL" > /etc/telemt/notify-email
    echo -e "  ${GREEN}✓ Alert email: $NOTIFY_EMAIL${NC}"
else
    echo "" > /etc/telemt/notify-email
    echo -e "  ${YELLOW}⚠ No alert email. Set with:${NC}"
    echo "    echo 'you@example.com' > /etc/telemt/notify-email"
fi

# Cron every 15 min
cat > /etc/cron.d/mtproxy-monitor << CRON
# MTProxy / telemt monitoring — latency from Russian nodes every 15 min
# Detects ТСПУ Stage 1 degradation before Stage 2 full block
# Log: /var/log/mtproxy-monitor.log
*/15 * * * * root /usr/local/bin/mtproxy-monitor >> /var/log/mtproxy-monitor.log 2>&1
CRON
chmod 644 /etc/cron.d/mtproxy-monitor

# Log rotation
cat > /etc/logrotate.d/mtproxy-monitor << LOGROTATE
/var/log/mtproxy-monitor.log {
    daily
    rotate 30
    compress
    missingok
    notifempty
    dateext
}
LOGROTATE

echo -e "  ${GREEN}✓ Monitor: /usr/local/bin/mtproxy-monitor${NC}"
echo -e "  ${GREEN}✓ Cron: every 15 min${NC}"
echo -e "  ${GREEN}✓ Log: /var/log/mtproxy-monitor.log${NC}"
echo ""

# ============================================================
# STEP 9: VERIFICATION
# ============================================================
echo -e "${BLUE}[9/9] Verification...${NC}"
echo ""

echo "  [9a] Service status:"
systemctl status telemt --no-pager -l 2>/dev/null | grep -E "Active|Main PID|Loaded" | sed 's/^/    /'
echo ""

echo "  [9b] Port $PORT listening:"
ss -tlnp | grep ":${PORT} " \
    && echo -e "    ${GREEN}✓ Listening${NC}" \
    || echo -e "    ${YELLOW}⚠ Not visible yet — check: journalctl -u telemt -n 20${NC}"
echo ""

echo "  [9c] Management API — connection links:"
sleep 2
API_RESULT=$(curl -s --max-time 5 http://127.0.0.1:9091/v1/users 2>/dev/null)
if [ -n "$API_RESULT" ]; then
    echo -e "    ${GREEN}✓ API responding${NC}"
    echo "$API_RESULT" | python3 << PYEOF
import sys, json
try:
    data = json.loads("""$API_RESULT""")
    if isinstance(data, list):
        for u in data:
            print(f"    User: {u.get('name','?')}")
            print(f"    Link: {u.get('link','?')}")
            print()
    elif isinstance(data, dict):
        for name, info in data.items():
            print(f"    User: {name}")
            if isinstance(info, dict):
                print(f"    Link: {info.get('link', info.get('url','?'))}")
            print()
except Exception as e:
    print(f"    (parse error: {e})")
    print(f"    Raw: $API_RESULT")
PYEOF
else
    echo -e "    ${YELLOW}⚠ API not yet ready — get links manually:${NC}"
    echo "    curl -s http://127.0.0.1:9091/v1/users | jq"
fi
echo ""

echo "  [9d] Real TLS verification (TCP Splice test):"
echo "       A scanner connecting without the secret should get real $MASK_DOMAIN cert."
TLS=$(echo -n | openssl s_client \
    -connect "${SERVER_IP}:${PORT}" \
    -servername "$MASK_DOMAIN" \
    -timeout 8 2>&1)

CERT_CN=$(echo "$TLS" | grep -oP "CN\s*=\s*\K[^\n,]+" | head -1)
CERT_ISSUER=$(echo "$TLS" | grep "issuer" | head -1 | sed 's/^[[:space:]]*//')

if echo "$TLS" | grep -q "SSL certificate verify ok"; then
    echo -e "    ${GREEN}✓ Real TLS — certificate verified OK${NC}"
    [ -n "$CERT_CN" ]     && echo "    CN    : $CERT_CN"
    [ -n "$CERT_ISSUER" ] && echo "    Issuer: $CERT_ISSUER" | cut -c1-70
    echo "    → DPI scanners see real $MASK_DOMAIN, NOT a fake TLS"
elif echo "$TLS" | grep -q "CONNECTED"; then
    echo -e "    ${CYAN}ℹ TLS connected — cert details:${NC}"
    [ -n "$CERT_CN" ] && echo "    CN: $CERT_CN"
else
    echo -e "    ${YELLOW}⚠ TLS not yet confirmed — mask domain may need a moment${NC}"
    echo "    Check: openssl s_client -connect ${SERVER_IP}:${PORT} -servername $MASK_DOMAIN"
fi
echo ""

echo "  [9e] First monitoring check (takes ~20 sec):"
/usr/local/bin/mtproxy-monitor 2>/dev/null \
    | grep -E "STATUS|latency|BLOCKED|Service|Local|CRIT|WARN|OK" \
    | sed 's/^/    /'
echo ""

# ============================================================
# FINAL OUTPUT
# ============================================================

# Get links from API if available
API_LINKS=$(curl -s --max-time 5 http://127.0.0.1:9091/v1/users 2>/dev/null)

echo "============================================================"
echo -e "${GREEN} ✓ MTProxy telemt v3.0 — installation complete!${NC}"
echo "============================================================"
echo ""
echo -e "${CYAN} Architecture:${NC}"
echo "  Mode         : TCP Splice (NOT FakeTLS)"
echo "  Mask domain  : $MASK_DOMAIN"
echo "  With secret  → MTProxy (Telegram)"
echo "  Without scrt → real TLS to $MASK_DOMAIN (real cert)"
echo "  DPI/scanner  → sees real $MASK_DOMAIN, JA3/JA4 fingerprint = real"
echo ""
echo -e "${CYAN} Connection links:${NC}"
if [ -n "$API_LINKS" ]; then
    echo "$API_LINKS" | python3 << PYEOF 2>/dev/null
import sys, json
try:
    data = json.loads("""$API_LINKS""")
    if isinstance(data, list):
        for u in data:
            print(f"  {u.get('name','user')}: {u.get('link','?')}")
    elif isinstance(data, dict):
        for name, info in data.items():
            link = info.get('link', info.get('url','?')) if isinstance(info,dict) else '?'
            print(f"  {name}: {link}")
except Exception as e:
    print(f"  (cannot parse API response)")
PYEOF
else
    echo "  curl -s http://127.0.0.1:9091/v1/users | jq"
fi
echo ""
echo -e "${CYAN} Telegram manual setup:${NC}"
echo "  Settings → Privacy → Use Proxy → Add Proxy → MTProto"
echo "  Server : $SERVER_IP"
echo "  Port   : $PORT"
echo "  Secret : (use full secret from links above, with ee prefix)"
echo ""
echo -e "${CYAN} Monitoring:${NC}"
echo "  Run check now  : mtproxy-monitor"
echo "  Watch log live : tail -f /var/log/mtproxy-monitor.log"
echo "  Schedule       : every 15 min"
if [ -n "$NOTIFY_EMAIL" ]; then
    echo "  Alert email    : $NOTIFY_EMAIL"
else
    echo "  Alert email    : echo 'you@example.com' > /etc/telemt/notify-email"
fi
echo ""
echo -e "${CYAN} Latency thresholds:${NC}"
echo "  >$LATENCY_WARN_MS ms = WARNING (elevated, logged)"
echo "  >$LATENCY_CRIT_MS ms = CRITICAL alert (ТСПУ degradation)"
echo "  no connect    = CRITICAL alert (full block)"
echo ""
echo -e "${CYAN} Managing users:${NC}"
echo "  Get all links  : curl -s http://127.0.0.1:9091/v1/users | jq"
echo "  Add user       : add to $TELEMT_CONFIG [access.users]"
echo "                   (no restart needed)"
echo "  New secret     : openssl rand -hex 16"
echo ""
echo -e "${CYAN} Service management:${NC}"
echo "  Status  : systemctl status telemt"
echo "  Logs    : journalctl -u telemt -f"
echo "  Restart : systemctl restart telemt"
echo "  Config  : $TELEMT_CONFIG"
echo ""
echo -e "${CYAN} Add @MTProxybot sponsorship:${NC}"
echo "  1. @MTProxybot → /newproxy → ${SERVER_IP}:${PORT}"
echo "  2. Send user secret from users.txt"
echo "  3. Copy tag from bot → add to $TELEMT_CONFIG:"
echo "     [general]"
echo "     ad_tag = \"<tag_from_bot>\""
echo "  4. systemctl restart telemt"
echo ""
echo -e "${CYAN} Change mask domain (if blocked):${NC}"
echo "  bash $0 $PORT www.apple.com"
echo ""
echo -e "${CYAN} Recommended mask domains:${NC}"
for d in "${GOOD_MASK_DOMAINS[@]}"; do
    [ "$d" = "$MASK_DOMAIN" ] \
        && echo -e "  ${GREEN}→ $d (current)${NC}" \
        || echo "    $d"
done
echo ""
echo -e "${YELLOW} When to act:${NC}"
echo "  Latency warning : watch next 15-min check"
echo "  Full block      : change VPS IP (most effective)"
echo "  Secret rotation : NOT needed — ТСПУ blocks IP:port, not secret"
echo "============================================================"
echo ""
