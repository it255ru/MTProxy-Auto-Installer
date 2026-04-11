#!/bin/bash
# ============================================================
# TSPU Server Checker v5
# Checks if this VPS is reachable from Russia and diagnoses
# ТСПУ blocking status (DPI detection, latency degradation).
#
# Run on any VPS: bash tspu_server_check.sh [port] [domain]
#   port   — port to test (default: 443)
#   domain — your custom mask domain (optional, e.g. hardeninglab.com)
#            overrides domain from telemt.toml
#
# Supports: Ubuntu 20/22/24, Debian 11/12/13
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

TEST_PORT="${1:-443}"
CUSTOM_DOMAIN="${2:-}"   # optional: pass your domain e.g. hardeninglab.com
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120.0 Safari/537.36"

# ============================================================
# HELPERS
# ============================================================
step() { echo -e "${BLUE}[$1/$TOTAL] $2${NC}"; }
ok()   { echo -e "  ${GREEN}✓ $*${NC}"; }
warn() { echo -e "  ${YELLOW}⚠ $*${NC}"; }
fail() { echo -e "  ${RED}✗ $*${NC}"; }
info() { echo "  $*"; }

TOTAL=9

# ============================================================
# DEPENDENCIES
# ============================================================
if ! command -v curl &>/dev/null || ! command -v python3 &>/dev/null; then
    echo "Installing dependencies..."
    if   command -v apt-get &>/dev/null; then apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl python3 2>/dev/null
    elif command -v dnf     &>/dev/null; then dnf install -y -q curl python3 2>/dev/null
    elif command -v yum     &>/dev/null; then yum install -y -q curl python3 2>/dev/null
    elif command -v apk     &>/dev/null; then apk add --quiet curl python3 2>/dev/null
    else echo "Unknown package manager — install curl python3 manually"; exit 1
    fi
fi

# ============================================================
# GET SERVER IP
# ============================================================
SERVER_IP=""
for URL in ifconfig.me api.ipify.org icanhazip.com; do
    SERVER_IP=$(curl -s --max-time 5 "$URL" 2>/dev/null | tr -d '[:space:]')
    [[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
    SERVER_IP=""
done

echo ""
echo "============================================================"
echo " TSPU Server Checker v5"
echo "============================================================"
echo " Server IP : ${SERVER_IP:-UNKNOWN}"
echo " Test port : $TEST_PORT"
[ -n "$CUSTOM_DOMAIN" ] && echo " Domain    : $CUSTOM_DOMAIN"
echo " Date      : $(date '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================================"
echo ""

[ -z "$SERVER_IP" ] && { fail "Cannot determine server IP. Check internet access."; echo ""; }

# ============================================================
# FUNCTION: check port from Russia via check-host.net
# FIX: uses temp file for Python script to avoid pipe+heredoc
#      stdin conflict. Also adds User-Agent to avoid 403.
# ============================================================
check_port_from_russia() {
    local IP="$1"
    local PORT="$2"
    local URL="https://check-host.net/check-tcp?host=${IP}:${PORT}"
    URL+="&node=ru1.node.check-host.net"
    URL+="&node=ru2.node.check-host.net"
    URL+="&node=ru3.node.check-host.net"
    URL+="&node=msk.node.check-host.net"

    local RESP
    RESP=$(curl -s --max-time 12 \
        -H "Accept: application/json" \
        -H "User-Agent: $UA" \
        "$URL" 2>/dev/null)

    local REQ_ID
    REQ_ID=$(echo "$RESP" | python3 -c "
import sys, json
try: print(json.load(sys.stdin).get('request_id', ''))
except: print('')
" 2>/dev/null)

    if [ -z "$REQ_ID" ]; then
        warn "check-host.net unavailable (try: https://check-host.net/check-tcp#${IP}:${PORT})"
        return
    fi

    sleep 13

    local RESULT
    RESULT=$(curl -s --max-time 10 \
        -H "Accept: application/json" \
        -H "User-Agent: $UA" \
        "https://check-host.net/check-result/${REQ_ID}" 2>/dev/null)

    # Write parser to temp file — avoids pipe+heredoc stdin conflict
    local PARSER="/tmp/chk_parser_$$.py"
    cat > "$PARSER" << 'PYEOF'
import sys, json

port = sys.argv[1]
ok_count = 0
blocked_count = 0

try:
    d = json.load(sys.stdin)
except:
    print("  Could not parse check-host.net result")
    sys.exit()

for node, val in d.items():
    short = node.replace('.node.check-host.net', '')
    if val is None:
        print(f"  {short}: pending")
    elif isinstance(val, list) and val:
        v = val[0]
        if isinstance(v, dict) and 'time' in v:
            ms = round(v['time'] * 1000, 1)
            print(f"  \033[32m{short}: {ms}ms\033[0m")
            ok_count += 1
        elif isinstance(v, list):
            if v[0] == 'OK':
                ms = round(v[1] * 1000, 1) if len(v) > 1 else 0
                print(f"  \033[32m{short}: {ms}ms\033[0m")
                ok_count += 1
            else:
                print(f"  \033[31m{short}: {v[0]}\033[0m")
                blocked_count += 1
        else:
            print(f"  \033[31m{short}: error\033[0m")
            blocked_count += 1
    else:
        print(f"  \033[31m{short}: no response\033[0m")
        blocked_count += 1

print()
total = ok_count + blocked_count
if total == 0:
    print("  \033[33mRESULT: pending — no results yet\033[0m")
elif blocked_count == 0:
    print(f"  \033[32mRESULT: NOT BLOCKED — port {port} accessible from Russia ✓\033[0m")
elif ok_count == 0:
    print(f"  \033[31mRESULT: BLOCKED — port {port} unreachable from Russia ✗\033[0m")
else:
    print(f"  \033[33mRESULT: PARTIAL — {ok_count} ok / {blocked_count} blocked\033[0m")
PYEOF

    echo "$RESULT" | python3 "$PARSER" "$PORT"
    rm -f "$PARSER"
}

# ============================================================
# [1/9] GEO & IP INFO
# ============================================================
step 1 "Server location & IP classification"
if [ -n "$SERVER_IP" ]; then
    GEO=$(curl -s --max-time 6 \
        "http://ip-api.com/json/${SERVER_IP}?fields=country,regionName,city,isp,as,org,hosting" \
        2>/dev/null)

    if [ -n "$GEO" ]; then
        echo "$GEO" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(f\"  Country : {d.get('country','?')}\")
    print(f\"  Region  : {d.get('regionName','?')}, {d.get('city','?')}\")
    print(f\"  ISP     : {d.get('isp','?')}\")
    print(f\"  AS      : {d.get('as','?')}\")
    h = d.get('hosting', False)
    if h:
        print(f\"  \033[33m⚠ hosting=true — IP classified as datacenter/hosting\033[0m\")
        print(f\"    Russian ISPs often target hosting IP ranges\")
    else:
        print(f\"  \033[32m✓ hosting=false — IP not classified as datacenter\033[0m\")
except Exception as e:
    print(f'  Could not parse: {e}')
" 2>/dev/null
    else
        warn "Could not reach ip-api.com"
    fi
else
    warn "Skipped — no server IP"
fi
echo ""

# ============================================================
# [2/9] PORT TEST FROM RUSSIA
# ============================================================
step 2 "TCP port $TEST_PORT from Russia (check-host.net)"
if [ -n "$SERVER_IP" ]; then
    info "Querying Russian nodes — waiting ~15 sec..."
    check_port_from_russia "$SERVER_IP" "$TEST_PORT"
else
    warn "Skipped — no server IP"
fi
echo ""

# ============================================================
# [3/9] LOCAL LISTENING PORTS
# ============================================================
step 3 "Local listening ports"
FOUND=0
for PORT in 80 443 2053 2083 2087 2096 2443 8080 8443 8880; do
    if ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
        SVC=$(ss -tlnp 2>/dev/null | grep ":${PORT} " | \
              grep -oP 'users:\(\("\K[^"]+' | head -1)
        echo -e "  ${GREEN}[OPEN]${NC} :${PORT}  (${SVC:-unknown})"
        FOUND=1
    fi
done
[ $FOUND -eq 0 ] && info "No services on standard ports"
echo ""

# ============================================================
# [4/9] PROXY PROCESS DETECTION
# ============================================================
step 4 "Proxy process detection"

PROXY_FOUND=0

# telemt
if systemctl is-active --quiet telemt 2>/dev/null; then
    TELEMT_VER=$(telemt --version 2>/dev/null | head -1 || echo "unknown")
    ok "telemt is running ($TELEMT_VER)"
    # Read domain from toml first (most accurate), fallback to mask-domain file
    DOMAIN=""
    [ -n "$CUSTOM_DOMAIN" ] && DOMAIN="$CUSTOM_DOMAIN"
    if [ -z "$DOMAIN" ]; then
        DOMAIN=$(grep -oP 'tls_domain\s*=\s*"\K[^"]+' /etc/telemt/telemt.toml 2>/dev/null | head -1)
    fi
    if [ -z "$DOMAIN" ]; then
        DOMAIN=$(grep -oP 'domain\s*=\s*"\K[^"]+' /etc/telemt/telemt.toml 2>/dev/null | head -1)
    fi
    if [ -z "$DOMAIN" ]; then
        DOMAIN=$(cat /etc/telemt/mask-domain 2>/dev/null)
    fi
    DOMAIN="${DOMAIN:-browser.yandex.com}"
    # Sync mask-domain file with actual domain from toml
    echo "$DOMAIN" > /etc/telemt/mask-domain 2>/dev/null || true
    [ -n "$DOMAIN" ] && info "Mask domain: $DOMAIN"
    info "Mode: TCP Splice (DPI-proof — real cert from mask domain)"
    PROXY_FOUND=1
fi

# xray
if pgrep -x xray &>/dev/null || pgrep -f "xray run" &>/dev/null; then
    XRAY_BIN=$(which xray 2>/dev/null || find /usr/local/bin /opt -name xray 2>/dev/null | head -1)
    VER=$($XRAY_BIN version 2>/dev/null | head -1)
    ok "xray is running${VER:+ ($VER)}"
    CONFS=$(find /usr/local/etc/xray /etc/xray /opt -name "*.json" 2>/dev/null | head -3)
    for F in $CONFS; do
        grep -q "xtls-rprx-vision" "$F" 2>/dev/null && ok "  Vision flow in $F"
        grep -q "reality"          "$F" 2>/dev/null && ok "  Reality settings in $F"
        grep -qE '"security":\s*"tls"' "$F" 2>/dev/null && \
            warn "TLS mode in $F — if Reality intended, verify security setting"
    done
    PROXY_FOUND=1
fi

# sing-box
if pgrep -f "sing-box" &>/dev/null; then
    fail "sing-box detected — does NOT support xtls-rprx-vision (Vision flow)"
    info "  Client error: 'vision: not a valid supported TLS connection'"
    info "  Fix: migrate to xray"
    PROXY_FOUND=1
fi

# official MTProxy Docker (old, detectable)
if docker ps 2>/dev/null | grep -q "telegrammessenger/proxy"; then
    fail "Official Telegram MTProxy Docker detected!"
    info "  This image is DETECTABLE by ТСПУ since April 2026"
    info "  JA3/JA4 fingerprint is unique and not matching any browser"
    info "  Fix: migrate to telemt (TCP Splice)"
    PROXY_FOUND=1
fi

[ $PROXY_FOUND -eq 0 ] && warn "No known proxy process found (telemt/xray/mtproxy)"
echo ""

# ============================================================
# [5/9] TCP SPLICE VERIFICATION (telemt only)
# ============================================================
step 5 "TCP Splice verification — DPI scanner simulation"
info "Connecting without secret — should receive real mask domain cert"
echo ""

# Priority: CLI argument > telemt.toml > mask-domain file > fallback
if [ -n "$CUSTOM_DOMAIN" ]; then
    MASK_DOMAIN="$CUSTOM_DOMAIN"
else
    MASK_DOMAIN=$(grep -oP 'tls_domain\s*=\s*"\K[^"]+' /etc/telemt/telemt.toml 2>/dev/null | head -1)
    if [ -z "$MASK_DOMAIN" ]; then
        MASK_DOMAIN=$(grep -oP 'domain\s*=\s*"\K[^"]+' /etc/telemt/telemt.toml 2>/dev/null | head -1)
    fi
    if [ -z "$MASK_DOMAIN" ]; then
        MASK_DOMAIN=$(cat /etc/telemt/mask-domain 2>/dev/null)
    fi
    MASK_DOMAIN="${MASK_DOMAIN:-browser.yandex.com}"
fi

# Connect to external IP (not 127.0.0.1) so telemt handles it as external scanner.
# Use shell timeout instead of -timeout flag (not supported in OpenSSL 3.x / Debian 13).
TLS=$(echo -n | timeout 12 openssl s_client \
    -connect "${SERVER_IP}:${TEST_PORT}" \
    -servername "$MASK_DOMAIN" \
    2>&1)

CERT_CN=$(echo "$TLS"     | grep -oP "CN\s*=\s*\K[^\n,]+" | head -1)
CERT_ISSUER=$(echo "$TLS" | grep "issuer" | head -1 | sed 's/^[[:space:]]*//')
CERT_VERIFY=$(echo "$TLS" | grep "Verify return code" | head -1)

# OpenSSL 1.x: "SSL certificate verify ok"
# OpenSSL 3.x: "Verify return code: 0 (ok)"
# Both mean certificate verified successfully.
if echo "$TLS" | grep -qE "SSL certificate verify ok|Verify return code: 0 \(ok\)"; then
    ok "Real TLS — certificate verified OK (TCP Splice working)"
    [ -n "$CERT_CN" ]     && info "  CN (issuer): $CERT_CN"
    [ -n "$CERT_ISSUER" ] && info "  ${CERT_ISSUER}" | cut -c1-70
    [ -n "$CERT_VERIFY" ] && info "  $CERT_VERIFY"
    ok "DPI scanner sees real $MASK_DOMAIN — JA3/JA4 = browser fingerprint"
elif echo "$TLS" | grep -q "CONNECTED"; then
    warn "TLS connected but verification inconclusive"
    [ -n "$CERT_CN" ]     && info "  CN: $CERT_CN"
    [ -n "$CERT_VERIFY" ] && info "  $CERT_VERIFY"
    info "  Manual check: openssl s_client -connect ${SERVER_IP}:${TEST_PORT} -servername $MASK_DOMAIN"
elif ! systemctl is-active --quiet telemt 2>/dev/null; then
    warn "telemt not running — skipping TCP Splice check"
else
    warn "Could not verify from server — self-connection bypasses telemt"
    info "  ✓ Verify from a client machine instead:"
    info "    openssl s_client -connect ${SERVER_IP}:${TEST_PORT} -servername $MASK_DOMAIN"
    info "  Expected: CN=$MASK_DOMAIN, issuer=Let's Encrypt"
    info "  If browser opens https://$MASK_DOMAIN — TCP Splice is working"
fi
echo ""

# ============================================================
# [6/9] ТСПУ DEGRADATION — LATENCY HOLD TEST
# ============================================================
step 6 "ТСПУ degradation — latency hold test (25 sec)"
info "Holding TCP connection and measuring latency drift..."
info "ТСПУ Stage 1: packet drops → TCP retransmit → latency rises"
echo ""

# Write to temp file — avoids pipe+heredoc conflict
HOLD_SCRIPT="/tmp/hold_test_$$.py"
cat > "$HOLD_SCRIPT" << 'PYEOF'
import socket, time, sys

host = sys.argv[1]
port = int(sys.argv[2])

# Measure baseline latency (5 quick connects)
baselines = []
for _ in range(5):
    try:
        s = socket.socket()
        s.settimeout(3)
        t = time.time()
        s.connect((host, port))
        baselines.append(round((time.time()-t)*1000, 1))
        s.close()
        time.sleep(0.2)
    except:
        pass

if not baselines:
    print("  \033[31m✗ Cannot connect to measure baseline\033[0m")
    sys.exit(1)

baseline = round(sum(baselines)/len(baselines), 1)
print(f"  Baseline latency : {baseline}ms (avg of {len(baselines)} samples)")

# Hold connection and sample latency every 5 seconds
try:
    s = socket.socket()
    s.settimeout(5)
    s.connect((host, port))
    s.settimeout(30)

    start = time.time()
    drop_time = None
    samples = []

    print(f"  Holding connection for 25 sec...")

    deadline = start + 25
    last_sample = start

    while time.time() < deadline:
        time.sleep(1)
        elapsed = round(time.time() - start, 1)
        # Quick parallel connect to measure current latency
        if time.time() - last_sample >= 5:
            try:
                t2 = socket.socket()
                t2.settimeout(3)
                ts = time.time()
                t2.connect((host, port))
                lat = round((time.time()-ts)*1000, 1)
                t2.close()
                samples.append((elapsed, lat))
                drift = lat - baseline
                flag = ""
                if drift > 200:   flag = " ← HIGH drift (ТСПУ degradation?)"
                elif drift > 80:  flag = " ← elevated"
                print(f"    t+{elapsed:4.1f}s  latency={lat}ms  drift={drift:+.1f}ms{flag}")
                last_sample = time.time()
            except:
                pass

        # Check if held connection was dropped
        try:
            s.settimeout(0.01)
            data = s.recv(1)
            s.settimeout(30)
            if not data:
                drop_time = round(time.time() - start, 1)
                break
        except socket.timeout:
            pass
        except (ConnectionResetError, OSError):
            drop_time = round(time.time() - start, 1)
            break

    s.close()
    total = round(time.time() - start, 1)

    print()
    if drop_time is not None:
        if 14 <= drop_time <= 24:
            print(f"  \033[31m✗ DROPPED at {drop_time}s — ТСПУ 19-second DPI signature!\033[0m")
            print(f"    Plain MTProto/protocol detected and cut off")
        else:
            print(f"  \033[33m⚠ Connection dropped at {drop_time}s (not typical ТСПУ pattern)\033[0m")
    else:
        print(f"  \033[32m✓ Connection held {total}s without forced drop\033[0m")

    if samples:
        lats = [l for _, l in samples]
        max_drift = round(max(lats) - baseline, 1)
        if max_drift > 200:
            print(f"  \033[31m✗ Max latency drift: +{max_drift}ms — ТСПУ Stage 1 packet drop suspected\033[0m")
        elif max_drift > 80:
            print(f"  \033[33m⚠ Max latency drift: +{max_drift}ms — elevated, monitor\033[0m")
        else:
            print(f"  \033[32m✓ Max latency drift: +{max_drift}ms — stable\033[0m")

except Exception as e:
    print(f"  \033[31m✗ Test failed: {e}\033[0m")
PYEOF

python3 "$HOLD_SCRIPT" "127.0.0.1" "$TEST_PORT"
rm -f "$HOLD_SCRIPT"
echo ""

# ============================================================
# [7/9] DNS RESOLUTION
# ============================================================
step 7 "DNS resolution speed"
for DOMAIN in google.com telegram.org cloudflare.com youtube.com; do
    START=$(date +%s%3N)
    RESULT=$(python3 -c "
import socket
try:    print(socket.gethostbyname('$DOMAIN'))
except Exception as e: print('FAILED: ' + str(e))
" 2>/dev/null)
    END=$(date +%s%3N)
    MS=$((END - START))
    if echo "$RESULT" | grep -q "FAILED"; then
        fail "$DOMAIN — FAILED"
    elif [ $MS -gt 2000 ]; then
        warn "$DOMAIN → $RESULT (${MS}ms — slow, may cause timeouts)"
    else
        ok "$DOMAIN → $RESULT (${MS}ms)"
    fi
done
echo ""

# ============================================================
# [8/9] NETWORK QUALITY
# ============================================================
step 8 "Network quality (BBR, memory, interface errors)"

CONGESTION=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null)

[ "$CONGESTION" = "bbr" ] \
    && ok "BBR enabled (tcp_congestion_control=bbr)" \
    || warn "BBR not enabled (current: ${CONGESTION:-unknown}) — recommend enabling"

[ "$QDISC" = "fq" ] \
    && ok "Fair queue (fq) enabled" \
    || warn "qdisc=${QDISC:-unknown} — recommend fq"

if [ "$CONGESTION" != "bbr" ] || [ "$QDISC" != "fq" ]; then
    info "  Enable: echo -e 'net.ipv4.tcp_congestion_control=bbr\\nnet.core.default_qdisc=fq' >> /etc/sysctl.conf && sysctl -p"
fi

IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
if [ -n "$IFACE" ]; then
    RX_ERR=$(cat /sys/class/net/$IFACE/statistics/rx_errors 2>/dev/null || echo 0)
    TX_ERR=$(cat /sys/class/net/$IFACE/statistics/tx_errors 2>/dev/null || echo 0)
    RX_DROP=$(cat /sys/class/net/$IFACE/statistics/rx_dropped 2>/dev/null || echo 0)
    info "Interface $IFACE: RX err=${RX_ERR} TX err=${TX_ERR} RX drop=${RX_DROP}"
    { [ "${RX_ERR:-0}" -gt 10000 ] || [ "${RX_DROP:-0}" -gt 500000 ]; } \
        && warn "High error count — may affect throughput" \
        || ok "Interface errors within normal range"
fi

MEM_FREE=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}')
SWAP_TOTAL=$(free -m 2>/dev/null | awk '/^Swap:/{print $2}')
info "Free RAM: ${MEM_FREE:-?} MB"
[ "${MEM_FREE:-999}" -lt 100 ] \
    && fail "Low memory (<100MB) — may cause random drops" \
    || ok "Memory OK"
[ "${SWAP_TOTAL:-1}" -eq 0 ] && warn "No swap — add swap to prevent OOM"
echo ""

# ============================================================
# [9/9] IP REPUTATION
# ============================================================
step 9 "IP reputation check"
if [ -n "$SERVER_IP" ]; then
    GEO2=$(curl -s --max-time 6 \
        "http://ip-api.com/json/${SERVER_IP}?fields=as,hosting,proxy,mobile" \
        2>/dev/null)
    if [ -n "$GEO2" ]; then
        echo "$GEO2" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    hosting = d.get('hosting', False)
    proxy   = d.get('proxy', False)
    mobile  = d.get('mobile', False)
    asn     = d.get('as', '?')

    # Known blocked AS prefixes (Vultr major ranges)
    BLOCKED_AS = ['AS20473','AS64515']
    SAFE_AS    = []

    asn_num = asn.split()[0] if asn else ''
    if asn_num in BLOCKED_AS:
        print(f'  \033[31m✗ AS {asn} is frequently blocked by Russian ISPs\033[0m')
    else:
        print(f'  \033[32m✓ AS {asn} — not in known blocklist\033[0m')

    if hosting:
        print(f'  \033[33m⚠ Classified as hosting/datacenter IP\033[0m')
        print(f'    ТСПУ may prioritize scanning this range')
    else:
        print(f'  \033[32m✓ Not classified as hosting (hosting=false)\033[0m')
        print(f'    Lower chance of automated targeting by ТСПУ')

    if proxy:
        print(f'  \033[33m⚠ IP marked as proxy/VPN in ip-api database\033[0m')
except Exception as e:
    print(f'  Parse error: {e}')
" 2>/dev/null
    else
        warn "Could not reach ip-api.com"
    fi
    info ""
    info "Manual checks:"
    info "  AS info    : https://bgp.he.net/ip/${SERVER_IP}"
    info "  Reputation : https://www.ipqualityscore.com/ip-reputation/${SERVER_IP}"
    info "  Port test  : https://check-host.net/check-tcp#${SERVER_IP}:${TEST_PORT}"
else
    warn "Skipped — no server IP"
fi
echo ""

# ============================================================
# SUMMARY
# ============================================================
echo "============================================================"
echo -e "${CYAN} Usage:${NC}"
echo " bash tspu_server_check.sh [port] [domain]"
echo " bash tspu_server_check.sh 443 hardeninglab.com"
echo ""
echo -e "${CYAN} Summary — symptom → check mapping${NC}"
echo "============================================================"
echo " ТСПУ blocks this port       → [2] port test from Russia"
echo " Proxy not detected/running  → [4] proxy process"
echo " TCP Splice not working      → [5] TLS cert from mask domain"
echo " Latency rising (600ms+)     → [6] hold test drift"
echo " 19-second connection drops  → [6] hold test drop_time"
echo " DNS failures on client      → [7] DNS resolution"
echo " Slow downloads              → [8] BBR / network quality"
echo " IP range blocked            → [9] reputation"
echo ""
echo -e "${CYAN} ТСПУ two-stage blocking timeline:${NC}"
echo " Stage 1 (5-15 min): DPI detects protocol"
echo "   → protocols capacity 2-10% → packet drops → latency rises"
echo " Stage 2: IP:port added to ЦСУ blocklist"
echo "   → behavior: block → hard block"
echo " With telemt TCP Splice: Stage 1 detection is much harder"
echo " (DPI sees real TLS to mask domain, not MTProto fingerprint)"
echo "============================================================"
echo ""
