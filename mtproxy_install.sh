#!/bin/bash
# ============================================================
# MTProxy Auto-Installer v3.1 — telemt (TCP Splice)
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

LATENCY_WARN_MS=150
LATENCY_CRIT_MS=400

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
echo " MTProxy Auto-Installer v3.1 — telemt TCP Splice"
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
    # dpkg returns "amd64" — we need uname for the raw kernel arch
    ARCH_DEB=$(dpkg --print-architecture 2>/dev/null || echo "")
    ARCH_UNAME=$(uname -m)
    echo "  OS       : $PRETTY_NAME"
    echo "  Arch(deb): ${ARCH_DEB:-n/a}"
    echo "  Arch(asm): $ARCH_UNAME"
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
# STEP 3: PRE-FLIGHT CHECKS
# ============================================================
echo -e "${BLUE}[3/9] Pre-flight checks...${NC}"

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

echo "  Checking mask domain reachability: $MASK_DOMAIN"
if curl -s --max-time 8 -o /dev/null -w "%{http_code}" \
        "https://${MASK_DOMAIN}/" 2>/dev/null | grep -q "^[23]"; then
    echo -e "  ${GREEN}✓ $MASK_DOMAIN is reachable (TLS works)${NC}"
else
    echo -e "  ${YELLOW}⚠ $MASK_DOMAIN unreachable from this VPS — telemt will still work${NC}"
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
    ufw python3 openssl jq mailutils tar file 2>/dev/null
echo -e "  ${GREEN}✓ Done${NC}"
echo ""

# ============================================================
# STEP 5: DOWNLOAD & INSTALL TELEMT
# ============================================================
echo -e "${BLUE}[5/9] Installing telemt...${NC}"

# FIX: telemt uses x86_64/aarch64 naming, NOT amd64/arm64
# dpkg reports "amd64" but telemt assets are named "x86_64"
# We must use uname -m (kernel arch) to match telemt's naming convention.
case "$ARCH_UNAME" in
    x86_64)          TELEMT_ARCH="x86_64"  ;;
    aarch64|arm64)   TELEMT_ARCH="aarch64" ;;
    armv7l)          TELEMT_ARCH="armv7"   ;;
    i386|i686)       TELEMT_ARCH="i686"    ;;
    *)
        echo -e "${YELLOW}  Unknown arch $ARCH_UNAME — trying x86_64${NC}"
        TELEMT_ARCH="x86_64"
        ;;
esac
echo "  Architecture: $ARCH_UNAME → telemt asset prefix: $TELEMT_ARCH"

# Skip download if already installed and working
if [ -x "$TELEMT_BIN" ] && "$TELEMT_BIN" --version &>/dev/null; then
    CURRENT_VER=$("$TELEMT_BIN" --version 2>/dev/null | head -1)
    echo -e "  ${GREEN}✓ telemt already installed: $CURRENT_VER${NC}"
else
    echo "  Fetching latest release info..."
    RELEASE_JSON=$(curl -s --max-time 15 "$TELEMT_RELEASE_URL" 2>/dev/null)
    TELEMT_VERSION=$(echo "$RELEASE_JSON" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d.get('tag_name',''))" 2>/dev/null)

    if [ -z "$TELEMT_VERSION" ]; then
        echo -e "${RED}  Cannot fetch release info from GitHub${NC}"
        exit 1
    fi
    echo "  Latest version: $TELEMT_VERSION"

    # Asset selection with priority scoring.
    # telemt naming: telemt-x86_64-linux-gnu.tar.gz
    # Priority: gnu libc > musl static > plain binary; skip v3 (needs AVX-512) and .sha256
    # Asset selection with priority scoring.
    # FIX: "echo $JSON | python3 - << HEREDOC" — heredoc replaces stdin,
    # pipe data is lost, json.load(sys.stdin) gets EOF → "parse error".
    # Fix: write selector to temp file, pipe JSON to it as normal stdin.
    ASSET_SELECTOR="/tmp/telemt_sel_$$.py"
    cat > "$ASSET_SELECTOR" << 'SELEOF'
import sys, json
arch = sys.argv[1]
def score(name):
    n = name.lower()
    if n.endswith('.sha256'): return 99
    if arch not in n:         return 98
    if 'linux' not in n:      return 97
    if 'v3' in n:             return 50
    if n.endswith('.tar.gz'):
        if 'gnu' in n:        return 1
        if 'musl' in n:       return 2
        return 3
    if n == 'telemt':         return 10
    return 5
try:
    data = json.load(sys.stdin)
    ranked = sorted([(score(a['name']), a['name'], a['browser_download_url'])
                     for a in data.get('assets', [])], key=lambda x: x[0])
    for s, name, url in ranked:
        if s < 90:
            sys.stderr.write(f"  Selected: {name} (score={s})\n")
            print(url)
            sys.exit(0)
    sys.stderr.write("No suitable asset found\n")
except Exception as e:
    sys.stderr.write(f"Asset parse error: {e}\n")
SELEOF
    DOWNLOAD_URL=$(echo "$RELEASE_JSON" | python3 "$ASSET_SELECTOR" "$TELEMT_ARCH")
    rm -f "$ASSET_SELECTOR"

    if [ -z "$DOWNLOAD_URL" ]; then
        echo -e "${RED}  Cannot find telemt binary for $TELEMT_ARCH${NC}"
        echo "  Available assets:"
        echo "$RELEASE_JSON" | python3 -c \
            "import sys,json; [print('   ', a['name']) for a in json.load(sys.stdin).get('assets',[])]" 2>/dev/null
        echo ""
        echo "  Manual steps:"
        echo "    curl -L -o /usr/local/bin/telemt \\"
        echo "      https://github.com/telemt/telemt/releases/latest/download/telemt-x86_64-linux-gnu.tar.gz"
        echo "    # Extract and place binary at /usr/local/bin/telemt"
        echo "    chmod +x /usr/local/bin/telemt && bash $0"
        exit 1
    fi

    echo "  Downloading: $DOWNLOAD_URL"
    TMP_ARCHIVE="/tmp/telemt_download_$$.tar.gz"
    TMP_DIR="/tmp/telemt_extract_$$"

    curl -L --max-time 120 --progress-bar -o "$TMP_ARCHIVE" "$DOWNLOAD_URL"
    if [ $? -ne 0 ] || [ ! -s "$TMP_ARCHIVE" ]; then
        echo -e "${RED}  Download failed${NC}"; rm -f "$TMP_ARCHIVE"; exit 1
    fi

    # Extract — handle .tar.gz or direct binary
    if file "$TMP_ARCHIVE" | grep -q "gzip\|tar"; then
        mkdir -p "$TMP_DIR"
        tar -xzf "$TMP_ARCHIVE" -C "$TMP_DIR" 2>/dev/null

        # Find the binary — search up to depth 5 to handle any archive structure
        EXTRACTED=$(find "$TMP_DIR" -maxdepth 5 -name "telemt" -type f 2>/dev/null | head -1)

        if [ -z "$EXTRACTED" ]; then
            echo -e "${RED}  Cannot find telemt binary in archive. Contents:${NC}"
            find "$TMP_DIR" -maxdepth 3 | sed 's/^/    /'
            rm -rf "$TMP_ARCHIVE" "$TMP_DIR"; exit 1
        fi

        mv "$EXTRACTED" "$TELEMT_BIN"
        rm -rf "$TMP_DIR"
    else
        # Direct binary (asset named "telemt" with no extension)
        mv "$TMP_ARCHIVE" "$TELEMT_BIN"
    fi

    rm -f "$TMP_ARCHIVE"
    chmod +x "$TELEMT_BIN"

    if [ ! -x "$TELEMT_BIN" ]; then
        echo -e "${RED}  telemt binary not executable${NC}"; exit 1
    fi
    echo -e "  ${GREEN}✓ telemt installed: $TELEMT_VERSION${NC}"
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

SECRET_USER1=$(openssl rand -hex 16)
SECRET_USER2=$(openssl rand -hex 16)

mkdir -p "$TELEMT_CONFIG_DIR"

# Save raw secrets for reference
cat > "$TELEMT_CONFIG_DIR/users.txt" << USERS
# telemt user secrets — generated $(date '+%Y-%m-%d %H:%M:%S UTC')
# Full tg:// links: curl -s http://127.0.0.1:9091/v1/users | jq
user1 = $SECRET_USER1
user2 = $SECRET_USER2
USERS
chmod 600 "$TELEMT_CONFIG_DIR/users.txt"

# Monitoring metadata
echo "$PORT"        > "$TELEMT_CONFIG_DIR/port"
echo "$SERVER_IP"   > "$TELEMT_CONFIG_DIR/server-ip"
echo "$MASK_DOMAIN" > "$TELEMT_CONFIG_DIR/mask-domain"

# Write telemt.toml
# NOTE: heredoc without quotes (<<TOML) so bash variables expand inside.
# Secrets are hex-only (openssl rand -hex 16) — safe for TOML string values.
cat > "$TELEMT_CONFIG" << TOML
# ============================================================
# telemt configuration — generated $(date '+%Y-%m-%d %H:%M:%S UTC')
# Docs: https://github.com/telemt/telemt
# ============================================================

[general]
use_middle_proxy = true

[general.modes]
# classic — obsolete plain MTProto, detectable
# secure  — dd-prefix obfuscation, still detectable by DPI
# tls     — TCP Splice: real TLS cert+handshake from mask host
classic = false
secure  = false
tls     = true

[general.tls]
# Connections without a valid secret are spliced to this domain.
# DPI scanners and crawlers receive:
#   - real TLS certificate chain (not self-signed, not fake)
#   - real TLS 1.3 handshake
#   - real HTTP response from the domain
# JA3/JA4 fingerprint is indistinguishable from a real browser.
domain = "$MASK_DOMAIN"

[server]
port    = $PORT
host    = "0.0.0.0"

# Management API — localhost only, used for /v1/users links
api_port = 9091
api_host = "127.0.0.1"

# Prometheus metrics — localhost only
metrics_port      = 9090
metrics_whitelist = ["127.0.0.1/32", "::1/128"]

max_connections = 10000

[access.users]
# Add more users: openssl rand -hex 16
# No service restart needed after adding users.
user1 = "$SECRET_USER1"
user2 = "$SECRET_USER2"

# [access.user_max_unique_ips]
# user1 = 3   # limit to 3 devices per link

# [access.user_ad_tags]
# user1 = "tag_from_mtproxybot"

[censorship]
# Splice unrecognized SNI connections to mask host instead of returning error.
# Prevents "Unknown TLS SNI" errors if clients use old links after domain change.
unknown_sni_action = "mask"
TOML
chmod 600 "$TELEMT_CONFIG"

echo -e "  ${MAGENTA}Config:${NC}"
echo "  Mask domain : $MASK_DOMAIN"
echo "  User1 secret: $SECRET_USER1"
echo "  User2 secret: $SECRET_USER2"
echo "  Config      : $TELEMT_CONFIG"
echo "  (Full tg:// links via: curl -s http://127.0.0.1:9091/v1/users | jq)"
echo ""

# ============================================================
# SYSTEMD SERVICE
# ============================================================
# FIX: ReadWritePaths must include /var/run (monitor status file)
# and /var/log (monitor log file). Without this, ProtectSystem=strict
# would block writes to these paths if telemt itself needed them.
# Monitor runs as root via cron so it's not affected, but being explicit is correct.
cat > /etc/systemd/system/telemt.service << SERVICE
[Unit]
Description=telemt MTProxy (TCP Splice TLS)
Documentation=https://github.com/telemt/telemt
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$TELEMT_BIN --config $TELEMT_CONFIG
Restart=always
RestartSec=5
LimitNOFILE=65536

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=$TELEMT_CONFIG_DIR /var/log /var/run

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable telemt 2>/dev/null
systemctl restart telemt
sleep 10

if systemctl is-active --quiet telemt; then
    echo -e "  ${GREEN}✓ telemt service running${NC}"
else
    echo -e "${RED}  telemt failed to start${NC}"
    journalctl -u telemt -n 30 --no-pager 2>/dev/null | sed 's/^/  /'
    exit 1
fi
echo ""

# ============================================================
# STEP 8: INSTALL MONITORING
# ============================================================
echo -e "${BLUE}[8/9] Installing monitoring...${NC}"
echo ""

echo "${NOTIFY_EMAIL:-}" > "$TELEMT_CONFIG_DIR/notify-email"
echo "$LATENCY_WARN_MS"  > "$TELEMT_CONFIG_DIR/latency-warn"
echo "$LATENCY_CRIT_MS"  > "$TELEMT_CONFIG_DIR/latency-crit"

cat > /usr/local/bin/mtproxy-monitor << 'PYEOF'
#!/usr/bin/env python3
"""
MTProxy Monitor (telemt) — detects ТСПУ degradation before full block.

ТСПУ two-stage blocking:
  Stage 1: DPI detects protocol → logs → ЦСУ analysis
           protocols capacity (2-10%) drops packets → TCP retransmits → LATENCY RISES
  Stage 2: IP:port added to cleaned blocklist → hard block (behavior: block)
  Window: 5-15 minutes between stages.

With telemt TCP Splice, DPI sees real TLS → Stage 1 detection is harder.
IP-based blocking (Eco Highway BGP) still applies if ЦСУ accumulates logs.
"""

import json, time, sys, socket, datetime, subprocess
import urllib.request
from datetime import timezone

def read_cfg(f, default=''):
    try: return open(f).read().strip()
    except: return default

SERVER_IP        = read_cfg('/etc/telemt/server-ip')
PORT             = int(read_cfg('/etc/telemt/port', '443'))
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
    return datetime.datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S')

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
        log(f"Alert sent: {subject}")
    except Exception as e:
        log(f"Alert failed: {e}", 'WARN')

def check_service():
    try:
        r = subprocess.run(['systemctl', 'is-active', 'telemt'],
                           capture_output=True, text=True, timeout=5)
        st = r.stdout.strip()
        return st == 'active', st
    except:
        return False, 'error'

def check_local_port():
    try:
        s = socket.socket()
        s.settimeout(5)
        t = time.time()
        s.connect(('127.0.0.1', PORT))  # 127.0.0.1 avoids UFW rate limit on external IP
        ms = round((time.time()-t)*1000, 1)
        s.close()
        return True, ms
    except Exception as e:
        return False, str(e)

def check_api():
    try:
        req = urllib.request.Request('http://127.0.0.1:9091/v1/users',
                                     headers={'Accept': 'application/json'})
        with urllib.request.urlopen(req, timeout=5) as r:
            return True, json.loads(r.read())
    except:
        return False, None

def check_from_russia():
    url = f"https://check-host.net/check-tcp?host={SERVER_IP}:{PORT}"
    for n in RU_NODES: url += f"&node={n}"
    try:
        req = urllib.request.Request(url, headers={'Accept': 'application/json', 'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120.0 Safari/537.36'})
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
            headers={'Accept': 'application/json', 'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120.0 Safari/537.36'})
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

# 1. Service
svc_ok, svc_st = check_service()
if not svc_ok:
    log(f"SERVICE DOWN: {svc_st}", 'CRIT')
    if last != 'CRIT':
        send_alert("[MTProxy] CRITICAL: telemt service not running",
                   f"Server: {SERVER_IP}:{PORT}\nStatus: {svc_st}\n\n"
                   f"Fix: systemctl restart telemt\n"
                   f"Logs: journalctl -u telemt -n 50")
    save_status('CRIT'); sys.exit(2)
log(f"Service: {svc_st}")

# 2. API
api_ok, _ = check_api()
log(f"API: {'ok' if api_ok else 'not responding (may be starting)'}")

# 3. Local port
local_ok, local_ms = check_local_port()
if not local_ok:
    log(f"LOCAL PORT FAILED: {local_ms}", 'CRIT')
    if last != 'CRIT':
        send_alert("[MTProxy] CRITICAL: Port not responding",
                   f"Port {PORT} on {SERVER_IP}: {local_ms}\n\nFix: systemctl restart telemt")
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
        flag = (' ← HIGH (ТСПУ degradation?)' if isinstance(ms, float) and ms > LATENCY_CRIT_MS
                else ' ← elevated' if isinstance(ms, float) and ms > LATENCY_WARN_MS else '')
        log(f"  {node}: {ms}ms{flag}")
    elif status is False:
        log(f"  {node}: BLOCKED ({ms})", 'WARN')
    else:
        log(f"  {node}: {ms}")

# ---- Determine status ----
if fail_nodes and len(fail_nodes) == len(ru) and ru:
    status = 'CRIT'
    log("STATUS: CRITICAL — fully blocked from Russia", 'CRIT')
    if last != 'CRIT':
        send_alert(
            "[MTProxy] CRITICAL: Fully blocked from Russia",
            f"MTProxy {SERVER_IP}:{PORT} unreachable from all Russian nodes.\n\n"
            f"IP:port is in ТСПУ blocklist (Stage 2 complete).\n\n"
            f"Results:\n" + "\n".join(f"  {n}: {m}" for n,m in fail_nodes) +
            f"\n\nActions:\n"
            f"  1. Change VPS IP — most effective\n"
            f"  2. Change mask domain: bash /root/mtproxy_install.sh {PORT} www.apple.com\n"
            f"  3. Change port: bash /root/mtproxy_install.sh 8443\n\n"
            f"Service is still running — only external IP:port is blocked.")

elif crit_lat:
    status = 'WARN'
    avg_ms = round(sum(ms for _,ms in crit_lat)/len(crit_lat), 1)
    log(f"STATUS: WARNING — latency {avg_ms}ms (ТСПУ Stage 1 degradation)", 'WARN')
    if last not in ('WARN', 'CRIT'):
        send_alert(
            f"[MTProxy] WARNING: Latency {avg_ms}ms — ТСПУ degradation signal",
            f"MTProxy {SERVER_IP}:{PORT} — HIGH LATENCY from Russia.\n"
            f"Average: {avg_ms}ms (threshold: {LATENCY_CRIT_MS}ms)\n\n"
            f"Nodes:\n" + "\n".join(f"  {n}: {ms}ms" for n,ms in crit_lat) +
            f"\n\nWith telemt TCP Splice this is unusual. Possible causes:\n"
            f"  a) General VPS routing degradation\n"
            f"  b) ТСПУ Stage 1 beginning\n\n"
            f"Full block may follow in 5-15 min. Monitor next check.")

elif fail_nodes and ok_nodes:
    status = 'WARN'
    log("STATUS: WARNING — partial block (ISP-level)", 'WARN')
    if last not in ('WARN', 'CRIT'):
        send_alert("[MTProxy] WARNING: Partial block from Russia",
                   f"Reachable: {', '.join(n for n,_ in ok_nodes)}\n"
                   f"Blocked:   {', '.join(n for n,_ in fail_nodes)}\n\n"
                   f"May be ISP-level block or routing issue.")

elif warn_lat:
    avg_ms = round(sum(ms for _,ms in warn_lat)/len(warn_lat), 1)
    status = 'WARN_LATENCY'
    log(f"STATUS: ELEVATED LATENCY — avg {avg_ms}ms (watching, no alert)")

else:
    status = 'OK'
    avg_ms = round(sum(ms for _,ms in ok_nodes)/len(ok_nodes), 1) if ok_nodes else 0
    log(f"STATUS: OK — avg latency from Russia: {avg_ms}ms")
    if last in ('WARN', 'CRIT'):
        send_alert("[MTProxy] RECOVERED: Proxy accessible from Russia",
                   f"MTProxy {SERVER_IP}:{PORT} is reachable again.\nPrevious: {last}")

save_status(status)
log("=== Check complete ===\n")
sys.exit(0 if status in ('OK', 'WARN_LATENCY') else (1 if status == 'WARN' else 2))
PYEOF

chmod +x /usr/local/bin/mtproxy-monitor

if [ -n "$NOTIFY_EMAIL" ]; then
    echo "$NOTIFY_EMAIL" > "$TELEMT_CONFIG_DIR/notify-email"
    echo -e "  ${GREEN}✓ Alert email: $NOTIFY_EMAIL${NC}"
else
    echo "" > "$TELEMT_CONFIG_DIR/notify-email"
    echo -e "  ${YELLOW}⚠ No alert email. Set: echo 'you@example.com' > /etc/telemt/notify-email${NC}"
fi

cat > /etc/cron.d/mtproxy-monitor << 'CRON'
# MTProxy / telemt — latency check from Russian nodes every 15 min
# Detects ТСПУ Stage 1 degradation before Stage 2 full block
# Log: /var/log/mtproxy-monitor.log
*/15 * * * * root /usr/local/bin/mtproxy-monitor >> /var/log/mtproxy-monitor.log 2>&1
CRON
chmod 644 /etc/cron.d/mtproxy-monitor

cat > /etc/logrotate.d/mtproxy-monitor << 'LOGROTATE'
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
echo -e "  ${GREEN}✓ Cron: every 15 min (/etc/cron.d/mtproxy-monitor)${NC}"
echo -e "  ${GREEN}✓ Log: /var/log/mtproxy-monitor.log (30-day rotation)${NC}"
echo ""

# ============================================================
# STEP 9: VERIFICATION
# ============================================================
echo -e "${BLUE}[9/9] Verification...${NC}"
echo ""

echo "  [9a] Service status:"
systemctl status telemt --no-pager -l 2>/dev/null \
    | grep -E "Active|Main PID|Loaded" | sed 's/^/    /'
echo ""

echo "  [9b] Port $PORT listening:"
ss -tlnp | grep ":${PORT} " \
    && echo -e "    ${GREEN}✓ Listening${NC}" \
    || echo -e "    ${YELLOW}⚠ Not visible yet — check: journalctl -u telemt -n 20${NC}"
echo ""

echo "  [9c] Connection links (from API):"
sleep 5
# FIX: pipe API response via stdin to python — avoids shell string interpolation
# and triple-quote injection risk with json.loads("""$VAR""")
API_RESULT=$(curl -s --max-time 5 http://127.0.0.1:9091/v1/users 2>/dev/null)
if [ -n "$API_RESULT" ]; then
    echo -e "    ${GREEN}✓ API responding${NC}"
    echo "$API_RESULT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if isinstance(data, list):
        for u in data:
            print(f\"    User: {u.get('name','?')}\")
            print(f\"    Link: {u.get('link', u.get('url','?'))}\")
            print()
    elif isinstance(data, dict):
        for name, info in data.items():
            link = info.get('link', info.get('url', '?')) if isinstance(info, dict) else str(info)
            print(f\"    User: {name}\")
            print(f\"    Link: {link}\")
            print()
except Exception as e:
    print(f\"    (parse error — run: curl -s http://127.0.0.1:9091/v1/users | jq)\")
"
else
    echo -e "    ${YELLOW}⚠ API not ready yet — run:${NC}"
    echo "    curl -s http://127.0.0.1:9091/v1/users | jq"
fi
echo ""

echo "  [9d] TCP Splice verification — scanner should get real $MASK_DOMAIN cert:"
TLS=$(echo -n | openssl s_client \
    -connect "${SERVER_IP}:${PORT}" \
    -servername "$MASK_DOMAIN" \
    -timeout 8 2>&1)
CERT_CN=$(echo "$TLS" | grep -oP "CN\s*=\s*\K[^\n,]+" | head -1)
CERT_ISSUER=$(echo "$TLS" | grep "issuer" | head -1 | sed 's/^[[:space:]]*//')
if echo "$TLS" | grep -q "SSL certificate verify ok"; then
    echo -e "    ${GREEN}✓ Real TLS — certificate verified OK${NC}"
    [ -n "$CERT_CN" ]     && echo "    CN    : $CERT_CN"
    [ -n "$CERT_ISSUER" ] && echo "    ${CERT_ISSUER}" | cut -c1-72
    echo "    → DPI sees real $MASK_DOMAIN (not fake TLS)"
elif echo "$TLS" | grep -q "CONNECTED"; then
    echo -e "    ${CYAN}ℹ TLS connected${NC}"
    [ -n "$CERT_CN" ] && echo "    CN: $CERT_CN"
else
    echo -e "    ${YELLOW}⚠ TLS inconclusive — check: journalctl -u telemt -n 20${NC}"
fi
echo ""

echo "  [9e] First monitoring check (~20 sec):"
/usr/local/bin/mtproxy-monitor 2>/dev/null \
    | grep -E "STATUS|latency|BLOCKED|Service|Local|CRIT|WARN|OK" \
    | sed 's/^/    /'
echo ""

# ============================================================
# FINAL OUTPUT
# ============================================================
echo "============================================================"
echo -e "${GREEN} ✓ MTProxy telemt v3.1 — installation complete!${NC}"
echo "============================================================"
echo ""
echo -e "${CYAN} Architecture:${NC}"
echo "  Mode        : TCP Splice"
echo "  Mask domain : $MASK_DOMAIN"
echo "  With secret → Telegram MTProxy"
echo "  Without key → real TLS to $MASK_DOMAIN (real cert, real fingerprint)"
echo "  DPI scanner → sees $MASK_DOMAIN, JA3/JA4 = real browser"
echo ""
echo -e "${CYAN} Connection links:${NC}"
curl -s --max-time 5 http://127.0.0.1:9091/v1/users 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if isinstance(data, list):
        for u in data:
            print(f\"  {u.get('name','user')}: {u.get('link', u.get('url','?'))}\")
    elif isinstance(data, dict):
        for name, info in data.items():
            link = info.get('link', info.get('url','?')) if isinstance(info,dict) else '?'
            print(f\"  {name}: {link}\")
except:
    print('  curl -s http://127.0.0.1:9091/v1/users | jq')
"
echo ""
echo -e "${CYAN} Telegram manual setup:${NC}"
echo "  Settings → Privacy → Use Proxy → Add Proxy → MTProto"
echo "  Server : $SERVER_IP"
echo "  Port   : $PORT"
echo "  Secret : (use full ee-prefixed secret from links above)"
echo ""
echo -e "${CYAN} Monitoring:${NC}"
echo "  Run now    : mtproxy-monitor"
echo "  Live log   : tail -f /var/log/mtproxy-monitor.log"
echo "  Schedule   : every 15 min"
[ -n "$NOTIFY_EMAIL" ] \
    && echo "  Email      : $NOTIFY_EMAIL" \
    || echo "  Email      : echo 'you@example.com' > /etc/telemt/notify-email"
echo ""
echo -e "${CYAN} Latency thresholds:${NC}"
echo "  > ${LATENCY_WARN_MS}ms = WARN_LATENCY (logged, no alert)"
echo "  > ${LATENCY_CRIT_MS}ms = WARNING email (ТСПУ Stage 1)"
echo "  no connect = CRITICAL email (ТСПУ Stage 2 full block)"
echo ""
echo -e "${CYAN} Users & links:${NC}"
echo "  All links  : curl -s http://127.0.0.1:9091/v1/users | jq"
echo "  Add user   : edit $TELEMT_CONFIG → [access.users] (no restart)"
echo "  New secret : openssl rand -hex 16"
echo ""
echo -e "${CYAN} Service:${NC}"
echo "  Status  : systemctl status telemt"
echo "  Logs    : journalctl -u telemt -f"
echo "  Restart : systemctl restart telemt"
echo "  Config  : $TELEMT_CONFIG"
echo ""
echo -e "${CYAN} If blocked — action order:${NC}"
echo "  1. CRITICAL latency alert → watch next 15-min check"
echo "  2. Full block → change VPS IP (most effective)"
echo "  3. Alternative → change mask domain:"
echo "     bash $0 $PORT www.apple.com"
echo "  4. Last resort → change port: bash $0 8443"
echo "  ✗ Secret rotation — does NOT help (ТСПУ blocks IP:port)"
echo ""
echo -e "${CYAN} Recommended mask domains:${NC}"
for d in "${GOOD_MASK_DOMAINS[@]}"; do
    [ "$d" = "$MASK_DOMAIN" ] \
        && echo -e "  ${GREEN}→ $d (current)${NC}" \
        || echo "    $d"
done
echo "============================================================"
echo ""
