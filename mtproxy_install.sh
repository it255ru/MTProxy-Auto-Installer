#!/bin/bash
# ============================================================
# MTProxy Auto-Installer v1.1
# Installs Docker + official Telegram MTProxy container
# Supports: Ubuntu 20/22/24, Debian 11/12/13
# Run as root: bash mtproxy_install.sh [port] [secret]
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

PORT="${1:-2443}"
SECRET="${2:-}"

# ============================================================
# ROOT CHECK
# ============================================================
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Run as root: sudo bash $0${NC}"
    exit 1
fi

# ============================================================
# HEADER
# ============================================================
echo ""
echo "============================================================"
echo " MTProxy Auto-Installer v1.1"
echo "============================================================"
echo " Port   : $PORT"
echo " Date   : $(date '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================================"
echo ""

# ============================================================
# STEP 1: DETECT OS
# ============================================================
echo -e "${BLUE}[1/8] Detecting OS...${NC}"

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    OS_VER=$VERSION_ID
    echo "  OS: $PRETTY_NAME"
else
    echo -e "${RED}Cannot detect OS${NC}"
    exit 1
fi

case $OS in
    ubuntu|debian) echo -e "  ${GREEN}✓ Supported OS${NC}" ;;
    *) echo -e "${YELLOW}⚠ Untested OS: $OS — proceeding anyway${NC}" ;;
esac
echo ""

# ============================================================
# STEP 2: INSTALL CURL FIRST, THEN GET SERVER IP
# ============================================================
echo -e "${BLUE}[2/8] Getting server IP...${NC}"

# Install curl before anything else if missing
if ! command -v curl &>/dev/null; then
    echo "  curl not found — installing..."
    apt-get update -qq 2>/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl 2>/dev/null
fi

SERVER_IP=""
for URL in ifconfig.me api.ipify.org icanhazip.com; do
    SERVER_IP=$(curl -s --max-time 5 "$URL" 2>/dev/null | tr -d '[:space:]')
    [[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
    SERVER_IP=""
done

if [ -z "$SERVER_IP" ]; then
    echo -e "${RED}Cannot determine server IP - check internet access${NC}"
    echo "Fix: ufw default allow outgoing && ufw reload"
    exit 1
fi

echo -e "  ${GREEN}✓ Server IP: $SERVER_IP${NC}"

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
# STEP 3: INSTALL DEPENDENCIES
# ============================================================
echo -e "${BLUE}[3/8] Installing dependencies...${NC}"

apt-get update -qq 2>/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    curl wget ca-certificates gnupg lsb-release \
    ufw python3 openssl 2>/dev/null

echo -e "  ${GREEN}✓ Base packages installed${NC}"
echo ""

# ============================================================
# STEP 4: INSTALL DOCKER
# ============================================================
echo -e "${BLUE}[4/8] Installing Docker...${NC}"

if command -v docker &>/dev/null; then
    DOCKER_VER=$(docker --version 2>/dev/null)
    echo -e "  ${GREEN}✓ Docker already installed: $DOCKER_VER${NC}"
else
    echo "  Installing Docker from official repo..."

    apt-get remove -y -qq docker docker-engine docker.io containerd runc 2>/dev/null

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/${OS}/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/${OS} \
        $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update -qq 2>/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin 2>/dev/null

    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}  Official repo failed, trying docker.io fallback...${NC}"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io 2>/dev/null
    fi

    if command -v docker &>/dev/null; then
        systemctl enable docker 2>/dev/null
        systemctl start docker 2>/dev/null
        echo -e "  ${GREEN}✓ Docker installed: $(docker --version)${NC}"
    else
        echo -e "${RED}  Docker installation failed${NC}"
        exit 1
    fi
fi

if ! systemctl is-active --quiet docker; then
    systemctl start docker
    sleep 2
fi
echo ""

# ============================================================
# STEP 5: CONFIGURE FIREWALL
# ============================================================
echo -e "${BLUE}[5/8] Configuring firewall (UFW)...${NC}"

ufw default allow outgoing 2>/dev/null
ufw default deny incoming 2>/dev/null

SSH_PORT=$(ss -tlnp | grep sshd | grep -oP ':\K[0-9]+' | head -1)
SSH_PORT="${SSH_PORT:-22}"
ufw allow "$SSH_PORT/tcp" comment "SSH" 2>/dev/null
echo "  SSH port: $SSH_PORT"

ufw allow "$PORT/tcp" comment "MTProxy" 2>/dev/null
echo "  MTProxy port: $PORT"

if ufw status | grep -q "Status: active"; then
    ufw reload 2>/dev/null
else
    ufw --force enable 2>/dev/null
fi

echo -e "  ${GREEN}✓ Firewall configured${NC}"
echo ""
ufw status | grep -E "Status|$PORT|$SSH_PORT" | sed 's/^/  /'
echo ""

# ============================================================
# STEP 6: GENERATE SECRET & START MTPROXY
# ============================================================
echo -e "${BLUE}[6/8] Starting MTProxy container...${NC}"

if [ -z "$SECRET" ]; then
    SECRET=$(openssl rand -hex 16)
    echo "  Generated new secret"
else
    if [[ ! "$SECRET" =~ ^[0-9a-fA-F]{32}$ ]]; then
        echo -e "${YELLOW}  Invalid secret format — generating new one${NC}"
        SECRET=$(openssl rand -hex 16)
    else
        echo "  Using provided secret"
    fi
fi

echo "  Secret: $SECRET"
echo "$SECRET" > /etc/mtproxy-secret
chmod 600 /etc/mtproxy-secret

docker rm -f mtproxy 2>/dev/null

echo "  Pulling telegrammessenger/proxy..."
docker pull telegrammessenger/proxy:latest 2>/dev/null

docker run -d \
    --name mtproxy \
    --restart always \
    -p "${PORT}:443" \
    -e SECRET="$SECRET" \
    -e WORKERS=4 \
    telegrammessenger/proxy:latest

if [ $? -ne 0 ]; then
    echo -e "${RED}  Failed to start container${NC}"
    docker logs mtproxy 2>/dev/null | tail -5
    exit 1
fi

sleep 5

if docker ps | grep -q mtproxy; then
    echo -e "  ${GREEN}✓ MTProxy container running${NC}"
else
    echo -e "${RED}  Container failed to start${NC}"
    docker logs mtproxy 2>/dev/null | tail -10
    exit 1
fi
echo ""

# ============================================================
# STEP 7: VERIFICATION CHECKS
# ============================================================
echo -e "${BLUE}[7/8] Running verification checks...${NC}"
echo ""

# 7a. Container status
echo "  [7a] Container status:"
docker ps --filter name=mtproxy --format "    ID: {{.ID}}  Status: {{.Status}}  Port: {{.Ports}}"
echo ""

# 7b. Port listening
echo "  [7b] Port check (server side):"
if ss -tlnp | grep -q ":${PORT} "; then
    SVC=$(ss -tlnp | grep ":${PORT} " | grep -oP 'users:\(\("\K[^"]+' | head -1)
    echo -e "    ${GREEN}✓ Port ${PORT} is listening (${SVC:-docker})${NC}"
else
    echo -e "    ${YELLOW}⚠ Port ${PORT} not yet visible in ss${NC}"
fi
echo ""

# 7c. TCP self-test
echo "  [7c] TCP self-connect test:"
python3 - "$SERVER_IP" "$PORT" << 'EOF'
import socket, time, sys
host, port = sys.argv[1], int(sys.argv[2])
try:
    s = socket.socket()
    s.settimeout(5)
    start = time.time()
    s.connect((host, port))
    ms = round((time.time()-start)*1000, 1)
    print(f"    \033[32m✓ Connected to {host}:{port} in {ms}ms\033[0m")
    s.close()
except Exception as e:
    print(f"    \033[31m✗ Failed: {e}\033[0m")
EOF
echo ""

# 7d. MTProxy logs — show only relevant lines, fix port in links
echo "  [7d] MTProxy logs:"
docker logs mtproxy 2>/dev/null \
    | grep -E "Secret|link|t\.me|tg://|Starting|ERROR|FAIL" \
    | sed "s/:443&/:${PORT}\&/g; s/port=443/port=${PORT}/g" \
    | head -10 \
    | sed 's/^/    /'
echo ""

# 7e. Check-host.net from Russia
echo "  [7e] Checking port ${PORT} from Russia via check-host.net..."
echo "       (waiting ~15 sec)"

RESP=$(curl -s --max-time 10 \
    -H "Accept: application/json" \
    "https://check-host.net/check-tcp?host=${SERVER_IP}:${PORT}&node=ru1.node.check-host.net&node=ru2.node.check-host.net&node=ru3.node.check-host.net" \
    2>/dev/null)

REQ_ID=$(python3 -c "
import sys,json
try: print(json.loads('''$RESP''').get('request_id',''))
except: print('')
" 2>/dev/null)

if [ -n "$REQ_ID" ]; then
    sleep 13
    RESULT=$(curl -s --max-time 10 \
        -H "Accept: application/json" \
        "https://check-host.net/check-result/${REQ_ID}" 2>/dev/null)

    python3 - "$RESULT" "$PORT" << 'EOF'
import sys, json
try:
    d = json.loads(sys.argv[1])
except:
    print("    Could not parse result")
    sys.exit()

port = sys.argv[2]
ok = 0
blocked = 0
for node, val in d.items():
    short = node.replace('.node.check-host.net','')
    if val is None:
        print(f"    {short}: pending")
    elif isinstance(val, list) and len(val) > 0:
        v = val[0]
        if isinstance(v, dict) and 'time' in v:
            ms = round(v['time']*1000,1)
            print(f"    \033[32m{short}: Connected ({ms}ms)\033[0m")
            ok += 1
        elif isinstance(v, list) and v[0]=='OK':
            ms = round(v[1]*1000,1) if len(v)>1 else 0
            print(f"    \033[32m{short}: Connected ({ms}ms)\033[0m")
            ok += 1
        else:
            err = v[0] if isinstance(v,list) else str(v)
            print(f"    \033[31m{short}: {err}\033[0m")
            blocked += 1
    else:
        print(f"    \033[31m{short}: no response\033[0m")
        blocked += 1

print()
if blocked == 0 and ok > 0:
    print(f"    \033[32m✓ NOT BLOCKED — port {port} accessible from Russia\033[0m")
elif ok == 0:
    print(f"    \033[31m✗ BLOCKED — port {port} unreachable from Russia\033[0m")
    print(f"    \033[33m  This IP range may be blocked by Russian ISPs\033[0m")
else:
    print(f"    \033[33m⚠ PARTIAL — {ok} ok / {blocked} blocked\033[0m")
EOF
else
    echo "    Could not reach check-host.net"
    echo "    Manual check: https://check-host.net/check-tcp#${SERVER_IP}:${PORT}"
fi
echo ""

# ============================================================
# STEP 8: AUTO-MAINTENANCE
# ============================================================
echo -e "${BLUE}[8/8] Setting up auto-maintenance...${NC}"

cat > /etc/cron.daily/mtproxy-update << CRON
#!/bin/bash
# Update Telegram MTProxy config daily
docker exec mtproxy curl -s https://core.telegram.org/getProxyConfig \
    -o /etc/telegram/backend.conf 2>/dev/null
docker restart mtproxy 2>/dev/null
CRON
chmod +x /etc/cron.daily/mtproxy-update

echo -e "  ${GREEN}✓ Daily config update cron installed${NC}"

RESTART=$(docker inspect mtproxy --format='{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null)
echo -e "  ${GREEN}✓ Container restart policy: ${RESTART:-always}${NC}"
echo ""

# ============================================================
# FINAL OUTPUT
# ============================================================
TGLINK="https://t.me/proxy?server=${SERVER_IP}&port=${PORT}&secret=${SECRET}"
TGLINK2="tg://proxy?server=${SERVER_IP}&port=${PORT}&secret=${SECRET}"

echo "============================================================"
echo -e "${GREEN} ✓ MTProxy installation complete!${NC}"
echo "============================================================"
echo ""
echo -e "${CYAN} Connection details:${NC}"
echo "  Server : $SERVER_IP"
echo "  Port   : $PORT"
echo "  Secret : $SECRET"
echo ""
echo -e "${CYAN} Share links:${NC}"
echo "  $TGLINK"
echo "  $TGLINK2"
echo ""
echo -e "${CYAN} Telegram manual setup:${NC}"
echo "  Settings → Privacy → Use Proxy → Add Proxy → MTProto"
echo "  Server : $SERVER_IP"
echo "  Port   : $PORT"
echo "  Secret : $SECRET"
echo ""
echo -e "${CYAN} Management commands:${NC}"
echo "  View logs  : docker logs mtproxy -f"
echo "  Restart    : docker restart mtproxy"
echo "  Stop       : docker stop mtproxy"
echo "  Status     : docker ps | grep mtproxy"
echo "  New secret : docker rm -f mtproxy && bash $0 $PORT"
echo ""
echo -e "${CYAN} Config saved to:${NC}"
echo "  Secret file: /etc/mtproxy-secret"
echo ""
echo -e "${CYAN} Manual port check from Russia:${NC}"
echo "  https://check-host.net/check-tcp#${SERVER_IP}:${PORT}"
echo "============================================================"
echo ""
