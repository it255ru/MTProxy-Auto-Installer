#!/bin/bash
# ============================================================
# TSPU Server Checker v4
# Checks if this server is blocked by Russian ISPs (TSPU/DPI)
# Run on any VPS: bash tspu_server_check.sh
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================================
# INSTALL DEPENDENCIES
# ============================================================
install_deps() {
    local missing=0
    command -v curl    &>/dev/null || missing=1
    command -v python3 &>/dev/null || missing=1

    [ $missing -eq 0 ] && return 0

    echo -e "${YELLOW}Installing dependencies...${NC}"
    if command -v apt-get &>/dev/null; then
        apt-get update -qq 2>/dev/null
        apt-get install -y -qq curl python3 2>/dev/null
    elif command -v dnf &>/dev/null; then
        dnf install -y -q curl python3 2>/dev/null
    elif command -v yum &>/dev/null; then
        yum install -y -q curl python3 2>/dev/null
    elif command -v apk &>/dev/null; then
        apk add --quiet curl python3 2>/dev/null
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm --quiet curl python3 2>/dev/null
    else
        echo -e "${RED}Unknown package manager — install curl python3 manually${NC}"
        exit 1
    fi

    if ! command -v curl &>/dev/null || ! command -v python3 &>/dev/null; then
        echo -e "${RED}Failed to install dependencies${NC}"
        exit 1
    fi
    echo -e "${GREEN}Dependencies installed${NC}"
    echo ""
}

install_deps

# ============================================================
# GET SERVER IP
# ============================================================
SERVER_IP=""
for URL in ifconfig.me api.ipify.org icanhazip.com ipecho.net/plain; do
    SERVER_IP=$(curl -s --max-time 5 "$URL" 2>/dev/null | tr -d '[:space:]')
    [[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
    SERVER_IP=""
done

echo ""
echo "============================================================"
echo " TSPU Server Checker v4"
echo "============================================================"
echo " Server IP : ${SERVER_IP:-UNKNOWN - no internet access?}"
echo " Date      : $(date '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================================"
echo ""

if [ -z "$SERVER_IP" ]; then
    echo -e "${RED}ERROR: Cannot determine server IP.${NC}"
    echo " Try: curl ifconfig.me"
    echo " Fix: ufw default allow outgoing && ufw reload"
    echo ""
fi

# ============================================================
# CHECK PORT FROM RUSSIA
# ============================================================
check_port_from_russia() {
    local IP=$1
    local PORT=$2
    local NODES="ru1.node.check-host.net&node=ru2.node.check-host.net&node=ru3.node.check-host.net"

    local RESP=$(curl -s --max-time 10 \
        -H "Accept: application/json" \
        "https://check-host.net/check-tcp?host=${IP}:${PORT}&node=${NODES}" 2>/dev/null)

    local REQ_ID=$(python3 - "$RESP" << 'EOF'
import sys, json
try: print(json.loads(sys.argv[1]).get('request_id', ''))
except: print('')
EOF
)

    if [ -z "$REQ_ID" ]; then
        echo "  Could not reach check-host.net"
        return
    fi

    sleep 12

    local RESULT=$(curl -s --max-time 10 \
        -H "Accept: application/json" \
        "https://check-host.net/check-result/${REQ_ID}" 2>/dev/null)

    python3 - "$RESULT" "$PORT" << 'EOF'
import sys, json

try:
    d = json.loads(sys.argv[1])
except:
    print("  Could not parse result")
    sys.exit()

port = sys.argv[2]
ok = 0
blocked = 0

for node, val in d.items():
    short = node.replace('.node.check-host.net', '')
    if val is None:
        print(f"  {short}: pending")
    elif isinstance(val, list) and len(val) > 0:
        v = val[0]
        if isinstance(v, dict) and 'time' in v:
            ms = round(v['time'] * 1000, 1)
            print(f"  \033[32m{short}: Connected ({ms}ms)\033[0m")
            ok += 1
        elif isinstance(v, list) and len(v) > 0:
            if v[0] == 'OK':
                ms = round(v[1] * 1000, 1) if len(v) > 1 else 0
                print(f"  \033[32m{short}: Connected ({ms}ms)\033[0m")
                ok += 1
            else:
                print(f"  \033[31m{short}: {v[0]}\033[0m")
                blocked += 1
        else:
            print(f"  \033[31m{short}: error - {v}\033[0m")
            blocked += 1
    else:
        print(f"  \033[31m{short}: no response\033[0m")
        blocked += 1

print()
total = ok + blocked
if total == 0:
    print("  RESULT: \033[33mNo results (pending)\033[0m")
elif blocked == 0:
    print(f"  RESULT: \033[32mNOT BLOCKED - port {port} accessible from Russia ✓\033[0m")
elif ok == 0:
    print(f"  RESULT: \033[31mBLOCKED - port {port} unreachable from Russia ✗\033[0m")
else:
    print(f"  RESULT: \033[33mPARTIAL - {ok} ok / {blocked} blocked\033[0m")
EOF
}

# ============================================================
# 1. GEO INFO
# ============================================================
echo -e "${BLUE}[1/9] Server location${NC}"
if [ -n "$SERVER_IP" ]; then
    GEO=$(curl -s --max-time 5 "http://ip-api.com/json/${SERVER_IP}?fields=country,regionName,isp,as" 2>/dev/null)
    if [ -n "$GEO" ]; then
        python3 - "$GEO" << 'EOF'
import sys, json
try:
    d = json.loads(sys.argv[1])
    print(f"  Country : {d.get('country','?')}")
    print(f"  Region  : {d.get('regionName','?')}")
    print(f"  ISP     : {d.get('isp','?')}")
    print(f"  AS      : {d.get('as','?')}")
except Exception as e:
    print(f"  Could not parse geo info: {e}")
EOF
    else
        echo "  Could not reach ip-api.com"
    fi
else
    echo "  Skipped - no IP"
fi
echo ""

# ============================================================
# 2. PORT 443
# ============================================================
echo -e "${BLUE}[2/9] TCP port 443 from Russia${NC}"
if [ -n "$SERVER_IP" ]; then
    echo " Checking... (waiting ~15 sec)"
    check_port_from_russia "$SERVER_IP" "443"
else
    echo "  Skipped - no IP"
fi
echo ""

# ============================================================
# 3. PORT 8443
# ============================================================
echo -e "${BLUE}[3/9] TCP port 8443 from Russia${NC}"
if [ -n "$SERVER_IP" ]; then
    echo " Checking... (waiting ~15 sec)"
    check_port_from_russia "$SERVER_IP" "8443"
else
    echo "  Skipped - no IP"
fi
echo ""

# ============================================================
# 4. LOCAL OPEN PORTS
# ============================================================
echo -e "${BLUE}[4/9] Local open ports${NC}"
FOUND=0
for PORT in 80 443 2053 2083 2087 2096 2443 8080 8443 8880; do
    if ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
        SVC=$(ss -tlnp 2>/dev/null | grep ":${PORT} " | grep -oP 'users:\(\("\K[^"]+' | head -1)
        echo -e "  ${GREEN}[OPEN]${NC} :${PORT}  (${SVC:-unknown})"
        FOUND=1
    fi
done
[ $FOUND -eq 0 ] && echo "  No ports open on standard ports"
echo ""

# ============================================================
# 5. TSPU DPI — 19-SECOND DROP TEST
# ============================================================
echo -e "${BLUE}[5/9] TSPU DPI — 19-second connection drop signature${NC}"
echo " Holding TCP connection to Telegram servers for 25 seconds..."

python3 << 'EOF'
import socket, time, sys

targets = [
    ('149.154.167.51', 443),
    ('149.154.175.53', 443),
    ('91.108.4.1',     443),
]

for host, port in targets:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(5)
        start = time.time()
        s.connect((host, port))
        s.settimeout(25)
        print(f"  Connected to {host}:{port} — holding 25 seconds...")
        try:
            data = s.recv(1)
            elapsed = round(time.time() - start, 1)
            print(f"  \033[33mGot data after {elapsed}s\033[0m")
        except socket.timeout:
            elapsed = round(time.time() - start, 1)
            print(f"  \033[32mConnection held {elapsed}s without drop ✓ (no 19s cut)\033[0m")
        except Exception as e:
            elapsed = round(time.time() - start, 1)
            if 14 <= elapsed <= 24:
                print(f"  \033[31mDROPPED at {elapsed}s ✗ — TSPU 19-second signature detected!\033[0m")
            else:
                print(f"  \033[33mDropped at {elapsed}s (not typical TSPU pattern)\033[0m")
        s.close()
        break
    except Exception as e:
        print(f"  Cannot reach {host}:{port} — {e}")
        continue
EOF
echo ""

# ============================================================
# 6. DNS RESOLUTION CHECK
# ============================================================
echo -e "${BLUE}[6/9] DNS resolution check (tunnel DNS leak symptom)${NC}"
echo " Testing resolution speed for popular domains..."

for DOMAIN in youtube.com google.com cloudflare.com telegram.org; do
    START=$(date +%s%3N)
    RESULT=$(python3 -c "
import socket
try:
    ip = socket.gethostbyname('$DOMAIN')
    print(ip)
except Exception as e:
    print('FAILED: ' + str(e))
" 2>/dev/null)
    END=$(date +%s%3N)
    MS=$((END - START))

    if echo "$RESULT" | grep -q "FAILED"; then
        echo -e "  ${RED}✗ $DOMAIN — FAILED ($RESULT)${NC}"
    elif [ $MS -gt 2000 ]; then
        echo -e "  ${YELLOW}⚠ $DOMAIN → $RESULT (${MS}ms — slow, may cause client DNS timeouts)${NC}"
    else
        echo -e "  ${GREEN}✓ $DOMAIN → $RESULT (${MS}ms)${NC}"
    fi
done
echo ""

# ============================================================
# 7. XRAY / PROXY CONFIG CHECK
# ============================================================
echo -e "${BLUE}[7/9] Xray/proxy config check (Vision flow symptom)${NC}"

if pgrep -x xray &>/dev/null || pgrep -f "xray run" &>/dev/null; then
    echo -e "  ${GREEN}✓ xray is running${NC}"
    XRAY_BIN=$(which xray 2>/dev/null || find /usr/local/bin /opt -name xray 2>/dev/null | head -1)
    if [ -n "$XRAY_BIN" ]; then
        VERSION=$($XRAY_BIN version 2>/dev/null | head -1)
        echo "    Version: ${VERSION:-unknown}"
    fi
    CONF=$(find /usr/local/etc/xray /etc/xray /opt -name "*.json" 2>/dev/null | head -3)
    for F in $CONF; do
        grep -q "xtls-rprx-vision" "$F" 2>/dev/null && \
            echo -e "  ${GREEN}✓ Vision flow (xtls-rprx-vision) found in $F${NC}"
        grep -q '"flow": ""' "$F" 2>/dev/null || grep -q '"flow":""' "$F" 2>/dev/null && \
            echo -e "  ${YELLOW}⚠ Empty flow in $F — Vision disabled${NC}"
        grep -q "reality" "$F" 2>/dev/null && \
            echo -e "  ${GREEN}✓ Reality settings found in $F${NC}"
        grep -q '"security": "tls"' "$F" 2>/dev/null && \
            echo -e "  ${YELLOW}⚠ TLS mode in $F — if Reality intended, check sec setting${NC}"
    done
elif pgrep -f "sing-box" &>/dev/null; then
    echo -e "  ${RED}✗ sing-box is running instead of xray${NC}"
    echo "    sing-box does NOT support xtls-rprx-vision (Vision flow)"
    echo "    Client will see: vision: not a valid supported TLS connection"
    echo "    Fix: switch server to xray"
elif docker ps 2>/dev/null | grep -q mtproxy; then
    echo -e "  ${GREEN}✓ MTProxy container is running${NC}"
else
    echo -e "  ${YELLOW}⚠ No known proxy process detected (xray / sing-box / mtproxy)${NC}"
fi
echo ""

# ============================================================
# 8. NETWORK QUALITY CHECK
# ============================================================
echo -e "${BLUE}[8/9] Network quality check (slow download symptom)${NC}"

CONGESTION=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
QDISC=$(sysctl net.core.default_qdisc 2>/dev/null | awk '{print $3}')

if [ "$CONGESTION" = "bbr" ]; then
    echo -e "  ${GREEN}✓ BBR enabled (congestion control = bbr)${NC}"
else
    echo -e "  ${YELLOW}⚠ BBR not enabled (current: ${CONGESTION:-unknown})${NC}"
    echo "    Fix: echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf && sysctl -p"
fi

if [ "$QDISC" = "fq" ]; then
    echo -e "  ${GREEN}✓ Fair queue (fq) enabled${NC}"
else
    echo -e "  ${YELLOW}⚠ qdisc = ${QDISC:-unknown} (recommended: fq)${NC}"
fi

IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
if [ -n "$IFACE" ]; then
    RX_ERR=$(cat /sys/class/net/$IFACE/statistics/rx_errors 2>/dev/null)
    TX_ERR=$(cat /sys/class/net/$IFACE/statistics/tx_errors 2>/dev/null)
    RX_DROP=$(cat /sys/class/net/$IFACE/statistics/rx_dropped 2>/dev/null)
    echo "  Interface: $IFACE"
    echo "  RX errors: ${RX_ERR:-0}, TX errors: ${TX_ERR:-0}, RX dropped: ${RX_DROP:-0}"
    if [ "${RX_ERR:-0}" -gt 1000 ] || [ "${RX_DROP:-0}" -gt 1000 ]; then
        echo -e "  ${YELLOW}⚠ High error count — may affect download speed${NC}"
    else
        echo -e "  ${GREEN}✓ Interface errors within normal range${NC}"
    fi
fi

MEM_FREE=$(free -m | awk '/^Mem:/{print $7}')
SWAP_TOTAL=$(free -m | awk '/^Swap:/{print $2}')
echo "  Free RAM : ${MEM_FREE:-?} MB"
if [ "${MEM_FREE:-999}" -lt 100 ]; then
    echo -e "  ${RED}✗ Low memory — may cause random connection drops${NC}"
else
    echo -e "  ${GREEN}✓ Memory OK${NC}"
fi
if [ "${SWAP_TOTAL:-0}" -eq 0 ]; then
    echo -e "  ${YELLOW}⚠ No swap — add swap to prevent OOM drops${NC}"
fi
echo ""

# ============================================================
# 9. KNOWN BLOCKED RANGES
# ============================================================
echo -e "${BLUE}[9/9] Known blocked/allowed IP ranges${NC}"
if [ -n "$SERVER_IP" ]; then
    python3 - "$SERVER_IP" << 'EOF'
import ipaddress, sys

ip_str = sys.argv[1]
try:
    ip = ipaddress.ip_address(ip_str)
except:
    print(f"  Invalid IP: {ip_str}")
    sys.exit()

blocked = [
    ('70.34.0.0/15',     'Vultr Stockholm'),
    ('78.141.192.0/18',  'Vultr Amsterdam'),
    ('45.76.0.0/16',     'Vultr US/EU'),
    ('149.28.0.0/16',    'Vultr US/EU'),
    ('108.61.0.0/16',    'Vultr US/EU'),
    ('207.246.0.0/16',   'Vultr US/EU'),
    ('66.42.0.0/16',     'Vultr US/EU'),
    ('104.238.128.0/17', 'Vultr US/EU'),
    ('45.32.0.0/16',     'Vultr US/EU'),
    ('136.244.64.0/18',  'Vultr Frankfurt'),
    ('139.180.0.0/16',   'Vultr Singapore/Tokyo'),
    ('167.179.0.0/16',   'Vultr'),
    ('155.138.0.0/16',   'Vultr'),
    ('64.176.0.0/16',    'Vultr'),
]

accessible = [
    ('185.185.68.0/22',  'Aeza EU - usually accessible'),
    ('194.165.16.0/24',  'Aeza EU - usually accessible'),
    ('45.87.212.0/22',   'MVPS.net - usually accessible'),
]

found = False
for cidr, desc in blocked:
    try:
        if ip in ipaddress.ip_network(cidr, strict=False):
            print(f"  \033[31m✗ WARNING: {ip} → {cidr} ({desc})\033[0m")
            print(f"  \033[31m  Often blocked by Russian ISPs (TSPU)\033[0m")
            found = True
    except: pass

for cidr, desc in accessible:
    try:
        if ip in ipaddress.ip_network(cidr, strict=False):
            print(f"  \033[32m✓ OK: {ip} → {cidr}\033[0m")
            print(f"  \033[32m  {desc}\033[0m")
            found = True
    except: pass

if not found:
    print(f"  {ip_str} not in any known range - check manually")
EOF
else
    echo "  Skipped - no IP"
fi

echo ""
echo "============================================================"
echo -e " ${CYAN}CLIENT SYMPTOMS → SERVER CHECKS MAPPING:${NC}"
echo " wsarecv ~19s drops    → see check [5] above"
echo " dns: exchange failed  → see check [6] above"
echo " vision: not valid TLS → see check [7] above"
echo " slow download         → see check [8] above"
echo ""
echo -e " ${CYAN}MANUAL CHECK:${NC}"
echo " https://check-host.net/check-tcp#${SERVER_IP}:443"
echo " https://check-host.net/check-tcp#${SERVER_IP}:8443"
echo "============================================================"
echo ""
