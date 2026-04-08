#!/bin/bash
# ============================================================
# TSPU Client Checker v2
# Run on Ubuntu/Debian client to diagnose VPN connectivity
# Simulates what a user behind TSPU would experience
#
# Usage: bash tspu_client_check.sh <server_ip> <port> [secret]
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SERVER_IP="${1:-}"
SERVER_PORT="${2:-443}"
SECRET="${3:-}"

# ============================================================
# INSTALL DEPENDENCIES
# ============================================================
install_deps() {
    local pkgs=""
    command -v curl      &>/dev/null || pkgs="$pkgs curl"
    command -v python3   &>/dev/null || pkgs="$pkgs python3"
    command -v openssl   &>/dev/null || pkgs="$pkgs openssl"
    command -v ip        &>/dev/null || pkgs="$pkgs iproute2"

    if ! command -v traceroute &>/dev/null && ! command -v tracepath &>/dev/null; then
        pkgs="$pkgs traceroute"
    fi

    if [ -n "$pkgs" ]; then
        echo -e "${YELLOW}Installing:$pkgs ...${NC}"
        apt-get update -qq 2>/dev/null
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $pkgs 2>/dev/null
    fi
    export PATH="$PATH:/usr/sbin:/sbin"
}

install_deps
export PATH="$PATH:/usr/sbin:/sbin"

# ============================================================
# GET CLIENT IP
# ============================================================
CLIENT_IP=""
for URL in https://api.ipify.org https://ifconfig.me https://icanhazip.com https://ipecho.net/plain; do
    CLIENT_IP=$(curl -s --max-time 5 --insecure "$URL" 2>/dev/null | tr -d '[:space:]')
    [[ "$CLIENT_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
    CLIENT_IP=""
done

if [ -z "$CLIENT_IP" ]; then
    CLIENT_IP=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1)
    [ -n "$CLIENT_IP" ] && CLIENT_IP="${CLIENT_IP} (local)"
fi

echo ""
echo "============================================================"
echo " TSPU Client Checker v2"
echo "============================================================"
echo " Client IP  : ${CLIENT_IP:-unknown}"
echo " Target     : ${SERVER_IP:-NOT SET}:${SERVER_PORT}"
echo " Date       : $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "============================================================"

if [ -z "$SERVER_IP" ]; then
    echo ""
    echo -e "${RED}Usage: bash $0 <server_ip> <port> [mtproxy_secret]${NC}"
    echo ""
    echo " VLESS/xray:  bash $0 <ip> 443"
    echo " MTProxy:     bash $0 <ip> 2443 <32-char-secret>"
    echo ""
    exit 1
fi
echo ""

# ============================================================
# 1. CLIENT LOCATION
# ============================================================
echo -e "${BLUE}[1/9] Client location${NC}"
REAL_IP=$(echo "$CLIENT_IP" | grep -oP '^[0-9.]+')
if [ -n "$REAL_IP" ]; then
    GEO=$(curl -s --max-time 5 "http://ip-api.com/json/${REAL_IP}?fields=country,regionName,isp,as" 2>/dev/null)
    python3 - "$GEO" << 'EOF'
import sys, json
try:
    raw = sys.argv[1].strip()
    if not raw:
        print("  Could not reach ip-api.com")
        sys.exit()
    d = json.loads(raw)
    print(f"  Country : {d.get('country','?')}")
    print(f"  Region  : {d.get('regionName','?')}")
    print(f"  ISP     : {d.get('isp','?')}")
    print(f"  AS      : {d.get('as','?')}")
except Exception as e:
    print(f"  Could not parse geo info: {e}")
EOF
else
    echo "  Skipped — could not determine public IP"
fi
echo ""

# ============================================================
# 2. BASIC TCP CONNECTIVITY
# ============================================================
echo -e "${BLUE}[2/9] Basic TCP connectivity to server${NC}"
echo " Testing TCP connect to ${SERVER_IP}:${SERVER_PORT}..."

python3 - "$SERVER_IP" "$SERVER_PORT" << 'EOF'
import socket, time, sys

host = sys.argv[1]
port = int(sys.argv[2])

try:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(10)
    start = time.time()
    s.connect((host, port))
    elapsed = round((time.time() - start) * 1000, 1)
    print(f"  \033[32m✓ TCP Connected in {elapsed}ms\033[0m")
    s.close()
except socket.timeout:
    print(f"  \033[31m✗ TCP TIMEOUT — port {port} blocked by firewall or TSPU\033[0m")
except ConnectionRefusedError:
    print(f"  \033[31m✗ CONNECTION REFUSED — nothing listening on port {port}\033[0m")
except Exception as e:
    print(f"  \033[31m✗ ERROR: {e}\033[0m")
EOF
echo ""

# ============================================================
# 3. TSPU DPI — 19-SECOND DROP TEST
# ============================================================
echo -e "${BLUE}[3/9] TSPU DPI — 19-second connection drop test${NC}"
echo " Holding TCP connection open for 25 seconds..."
echo " (Client symptom: wsarecv / forcibly closed at ~19s)"

python3 - "$SERVER_IP" "$SERVER_PORT" << 'EOF'
import socket, time, sys

host = sys.argv[1]
port = int(sys.argv[2])

try:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(5)
    start = time.time()
    s.connect((host, port))
    s.settimeout(26)
    print(f"  Connected. Holding silently for 25 seconds...")
    drop_time = None
    try:
        data = s.recv(4096)
        elapsed = round(time.time() - start, 2)
        if not data:
            drop_time = elapsed
        else:
            print(f"  Got {len(data)} bytes at {elapsed}s (normal)")
    except socket.timeout:
        elapsed = round(time.time() - start, 2)
        print(f"  \033[32m✓ Connection held {elapsed}s — NO 19-second drop\033[0m")
        print(f"  \033[32m  TSPU is not cutting this connection\033[0m")
    except (ConnectionResetError, OSError):
        elapsed = round(time.time() - start, 2)
        drop_time = elapsed

    if drop_time is not None:
        if 14 <= drop_time <= 24:
            print(f"  \033[31m✗ DROPPED at {drop_time}s — TSPU 19-second DPI signature!\033[0m")
            print(f"  \033[31m  Matches: wsarecv / forcibly closed by remote host\033[0m")
            print(f"  \033[33m  Fix: enable Reality or FakeTLS on server\033[0m")
        else:
            print(f"  \033[33m⚠ Dropped at {drop_time}s (not typical TSPU 19s pattern)\033[0m")
    s.close()
except socket.timeout:
    print(f"  \033[31m✗ Cannot connect — server unreachable\033[0m")
except ConnectionRefusedError:
    print(f"  \033[31m✗ Connection refused — nothing on port {port}\033[0m")
except Exception as e:
    print(f"  \033[31m✗ Error: {e}\033[0m")
EOF
echo ""

# ============================================================
# 4. TLS HANDSHAKE CHECK
# ============================================================
echo -e "${BLUE}[4/9] TLS handshake check (sec=tls vs reality symptom)${NC}"

if command -v openssl &>/dev/null; then
    TLS_RESULT=$(echo "Q" | timeout 5 openssl s_client \
        -connect "${SERVER_IP}:${SERVER_PORT}" \
        -servername "example.com" \
        2>&1)

    if echo "$TLS_RESULT" | grep -q "^CONNECTED"; then
        if echo "$TLS_RESULT" | grep -q "Cipher\|TLS\|SSL"; then
            CIPHER=$(echo "$TLS_RESULT" | grep "Cipher is\|New," | head -1 | sed 's/^[[:space:]]*//')
            CN=$(echo "$TLS_RESULT" | grep "subject=" | head -1 | sed 's/^[[:space:]]*//')
            echo -e "  ${YELLOW}⚠ Server responds to plain TLS handshake${NC}"
            echo "    $CIPHER"
            [ -n "$CN" ] && echo "    $CN"
            echo "    Note: VLESS+TLS — expected behaviour"
            echo "    Note: Reality servers should NOT respond to plain TLS"
        fi
    elif echo "$TLS_RESULT" | grep -qiE "refused|timeout|reset|EINVAL|errno"; then
        echo -e "  ${GREEN}✓ No plain TLS response — correct for Reality/MTProxy${NC}"
    else
        echo -e "  ${YELLOW}⚠ Unexpected TLS response${NC}"
    fi
else
    echo "  openssl not available — skipping"
fi
echo ""

# ============================================================
# 5. MTPROXY SECRET FORMAT CHECK
# ============================================================
echo -e "${BLUE}[5/9] MTProxy secret format check${NC}"
if [ -n "$SECRET" ]; then
    python3 - "$SECRET" << 'EOF'
import sys

secret = sys.argv[1].strip()
length = len(secret)
print(f"  Secret : {secret[:8]}...{secret[-4:]}")
print(f"  Length : {length} chars")

if length == 32:
    try:
        bytes.fromhex(secret)
        print(f"  \033[32m✓ Standard secret (32 hex) — basic mode\033[0m")
    except:
        print(f"  \033[31m✗ Not valid hex\033[0m")
elif length == 34 and secret.startswith('dd'):
    print(f"  \033[32m✓ DD-secret (obfuscation enabled)\033[0m")
elif secret.startswith('ee') and length > 34:
    domain_hex = secret[34:]
    try:
        domain = bytes.fromhex(domain_hex).decode('ascii')
        print(f"  \033[32m✓ FakeTLS secret — disguise domain: {domain}\033[0m")
        print(f"  \033[32m  Best mode for TSPU bypass\033[0m")
    except:
        print(f"  \033[31m✗ ee-prefix but invalid domain hex\033[0m")
else:
    print(f"  \033[31m✗ Invalid format!\033[0m")
    print(f"    Valid formats: 32 hex | dd+32 hex | ee+32 hex+domain_hex")
EOF
else
    echo "  Skipped — pass secret as 3rd argument for MTProxy check"
    echo "  Example: bash $0 $SERVER_IP $SERVER_PORT YOUR_SECRET_HERE"
fi
echo ""

# ============================================================
# 6. DNS CHECK
# ============================================================
echo -e "${BLUE}[6/9] DNS resolution check (dns: exchange failed symptom)${NC}"
echo " Testing direct DNS (without VPN)..."

for DOMAIN in youtube.com google.com telegram.org cloudflare.com; do
    START=$(date +%s%3N)
    RESULT=$(python3 -c "
import socket
try:
    ip = socket.gethostbyname('$DOMAIN')
    print(ip)
except Exception as e:
    print('FAILED:' + str(e))
" 2>/dev/null)
    END=$(date +%s%3N)
    MS=$((END - START))

    if echo "$RESULT" | grep -q "^FAILED"; then
        echo -e "  ${RED}✗ $DOMAIN — FAILED${NC}"
    elif [ $MS -gt 2000 ]; then
        echo -e "  ${YELLOW}⚠ $DOMAIN → $RESULT (${MS}ms — SLOW, will cause tunnel DNS timeouts)${NC}"
    else
        echo -e "  ${GREEN}✓ $DOMAIN → $RESULT (${MS}ms)${NC}"
    fi
done
echo ""

# ============================================================
# 7. TRACEROUTE — where does it drop
# ============================================================
echo -e "${BLUE}[7/9] Route to server (where does packet drop?)${NC}"

TRACE_CMD=""
command -v traceroute &>/dev/null && TRACE_CMD="traceroute -m 15 -w 3 -n"
command -v tracepath  &>/dev/null && [ -z "$TRACE_CMD" ] && TRACE_CMD="tracepath -n -m 15"
[ -z "$TRACE_CMD" ] && [ -x /usr/sbin/traceroute ] && TRACE_CMD="/usr/sbin/traceroute -m 15 -w 3 -n"

if [ -n "$TRACE_CMD" ]; then
    echo " Running: $TRACE_CMD $SERVER_IP"
    $TRACE_CMD "$SERVER_IP" 2>/dev/null | while IFS= read -r line; do
        if echo "$line" | grep -qE '^\s*[0-9]+\s+\*\s+\*\s+\*'; then
            echo -e "  ${YELLOW}$line  ← packet lost${NC}"
        else
            echo "  $line"
        fi
    done
else
    echo "  traceroute/tracepath not found"
    echo "  Trying python TTL probe fallback..."
    python3 - "$SERVER_IP" "$SERVER_PORT" << 'EOF'
import socket, time, sys

host = sys.argv[1]
port = int(sys.argv[2])

for ttl in [1, 2, 3, 5, 8, 12, 16, 20, 30, 64]:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.IPPROTO_IP, socket.IP_TTL, ttl)
        s.settimeout(2)
        start = time.time()
        s.connect((host, port))
        elapsed = round((time.time() - start) * 1000, 1)
        print(f"  TTL={ttl:2d}: Connected in {elapsed}ms ✓")
        s.close()
        break
    except socket.timeout:
        print(f"  TTL={ttl:2d}: timeout")
    except ConnectionRefusedError:
        print(f"  TTL={ttl:2d}: refused (reached server at ~hop {ttl})")
        break
    except OSError as e:
        print(f"  TTL={ttl:2d}: {e}")
    except Exception as e:
        print(f"  TTL={ttl:2d}: {e}")
EOF
fi
echo ""

# ============================================================
# 8. TCP LATENCY / JITTER
# ============================================================
echo -e "${BLUE}[8/9] TCP latency & jitter (slow download symptom)${NC}"
echo " Measuring 10 connection samples to ${SERVER_IP}:${SERVER_PORT}..."

python3 - "$SERVER_IP" "$SERVER_PORT" << 'EOF'
import socket, time, sys

host = sys.argv[1]
port = int(sys.argv[2])
samples = []

for i in range(10):
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(5)
        start = time.time()
        s.connect((host, port))
        elapsed = round((time.time() - start) * 1000, 1)
        samples.append(elapsed)
        s.close()
        time.sleep(0.3)
    except:
        samples.append(None)

valid = [x for x in samples if x is not None]
failed = len(samples) - len(valid)

if not valid:
    print(f"  \033[31m✗ All connections failed — server unreachable\033[0m")
    sys.exit()

avg    = round(sum(valid)/len(valid), 1)
mn     = min(valid)
mx     = max(valid)
jitter = round(mx - mn, 1)

print(f"  Samples : {len(valid)}/10 ok, {failed} failed")
print(f"  Latency : min={mn}ms  avg={avg}ms  max={mx}ms")
print(f"  Jitter  : {jitter}ms")

if failed > 2:
    print(f"  \033[31m✗ {failed} dropped connections — TSPU interference likely\033[0m")
elif jitter > 150:
    print(f"  \033[31m✗ High jitter ({jitter}ms) — will cause slow/interrupted downloads\033[0m")
elif jitter > 50:
    print(f"  \033[33m⚠ Moderate jitter ({jitter}ms) — may affect video streaming\033[0m")
else:
    print(f"  \033[32m✓ Latency stable (jitter {jitter}ms)\033[0m")

if avg > 300:
    print(f"  \033[33m⚠ High avg latency ({avg}ms) — server is far away\033[0m")
elif avg < 50:
    print(f"  \033[32m✓ Low latency ({avg}ms)\033[0m")
EOF
echo ""

# ============================================================
# 9. SUMMARY
# ============================================================
echo -e "${BLUE}[9/9] Summary${NC}"
echo ""

TCP_OK=$(python3 - "$SERVER_IP" "$SERVER_PORT" << 'EOF'
import socket, sys
try:
    s = socket.socket()
    s.settimeout(5)
    s.connect((sys.argv[1], int(sys.argv[2])))
    s.close()
    print("1")
except:
    print("0")
EOF
)

if [ "$TCP_OK" = "1" ]; then
    echo -e "  ${GREEN}✓ Server ${SERVER_IP}:${SERVER_PORT} is reachable from this client${NC}"
else
    echo -e "  ${RED}✗ Server ${SERVER_IP}:${SERVER_PORT} is NOT reachable from this client${NC}"
    echo "    Possible causes:"
    echo "    - Server port not open (check ufw on server)"
    echo "    - TSPU blocking this IP range"
    echo "    - Proxy process not running on server"
fi

echo ""
echo "  Symptom → Check mapping:"
echo "  ┌──────────────────────────────────────────────────────────┐"
echo "  │ wsarecv / forcibly closed at ~19s  → [3] DPI test       │"
echo "  │ sec=tls instead of reality         → [4] TLS handshake  │"
echo "  │ MTProxy invalid secret             → [5] Secret format  │"
echo "  │ dns: exchange failed / EOF         → [6] DNS check      │"
echo "  │ packets lost, slow route           → [7] Traceroute     │"
echo "  │ slow download / video stutters     → [8] Jitter check   │"
echo "  │ vision: not a valid TLS connection → use xray not sing  │"
echo "  └──────────────────────────────────────────────────────────┘"
echo ""
echo "============================================================"
echo -e " ${CYAN}MANUAL CHECKS:${NC}"
echo " Port test from Russia:"
echo "   https://check-host.net/check-tcp#${SERVER_IP}:${SERVER_PORT}"
echo " IP reputation:"
echo "   https://bgp.he.net/ip/${SERVER_IP}"
echo "   https://www.ipqualityscore.com/ip-reputation/${SERVER_IP}"
echo "============================================================"
echo ""
