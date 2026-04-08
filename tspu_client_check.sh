#!/bin/bash
# ============================================================
# TSPU Client Checker v3
# Run on client machine to diagnose connectivity to a proxy
# server through ТСПУ/DPI filtering.
#
# Usage: bash tspu_client_check.sh <server_ip> <port> [secret]
#   server_ip — VPS IP address
#   port      — proxy port (default: 443)
#   secret    — MTProxy secret (optional, for format check)
#
# Supports: Ubuntu 20/22/24, Debian 11/12/13
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
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120.0 Safari/537.36"

ok()   { echo -e "  ${GREEN}✓ $*${NC}"; }
warn() { echo -e "  ${YELLOW}⚠ $*${NC}"; }
fail() { echo -e "  ${RED}✗ $*${NC}"; }
info() { echo "  $*"; }

TOTAL=9

# ============================================================
# DEPENDENCIES
# ============================================================
install_deps() {
    local pkgs=""
    command -v curl    &>/dev/null || pkgs="$pkgs curl"
    command -v python3 &>/dev/null || pkgs="$pkgs python3"
    command -v openssl &>/dev/null || pkgs="$pkgs openssl"
    command -v ip      &>/dev/null || pkgs="$pkgs iproute2"
    command -v traceroute &>/dev/null || pkgs="$pkgs traceroute"

    if [ -n "$pkgs" ]; then
        echo "Installing:$pkgs"
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
for URL in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
    CLIENT_IP=$(curl -s --max-time 5 "$URL" 2>/dev/null | tr -d '[:space:]')
    [[ "$CLIENT_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
    CLIENT_IP=""
done

echo ""
echo "============================================================"
echo " TSPU Client Checker v3"
echo "============================================================"
echo " Client IP : ${CLIENT_IP:-unknown}"
echo " Target    : ${SERVER_IP:-NOT SET}:${SERVER_PORT}"
echo " Date      : $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "============================================================"

if [ -z "$SERVER_IP" ]; then
    echo ""
    echo -e "${RED}Usage: bash $0 <server_ip> <port> [mtproxy_secret]${NC}"
    echo ""
    echo " MTProxy:    bash $0 1.2.3.4 443 ee47baa7...secret..."
    echo " VLESS/xray: bash $0 1.2.3.4 443"
    echo ""
    exit 1
fi
echo ""

# ============================================================
# [1/9] CLIENT LOCATION
# ============================================================
echo -e "${BLUE}[1/$TOTAL] Client location & ISP${NC}"
REAL_IP=$(echo "$CLIENT_IP" | grep -oP '^[0-9.]+')
if [ -n "$REAL_IP" ]; then
    curl -s --max-time 6 \
        "http://ip-api.com/json/${REAL_IP}?fields=country,regionName,isp,as" \
        2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(f\"  Country : {d.get('country','?')}\")
    print(f\"  Region  : {d.get('regionName','?')}\")
    print(f\"  ISP     : {d.get('isp','?')}\")
    print(f\"  AS      : {d.get('as','?')}\")
except Exception as e:
    print(f'  Could not parse: {e}')
" 2>/dev/null
else
    warn "Could not determine public IP"
fi
echo ""

# ============================================================
# [2/9] BASIC TCP CONNECTIVITY
# ============================================================
echo -e "${BLUE}[2/$TOTAL] Basic TCP connectivity${NC}"
info "Connecting to ${SERVER_IP}:${SERVER_PORT}..."

python3 -c "
import socket, time, sys
host, port = '$SERVER_IP', $SERVER_PORT
try:
    s = socket.socket()
    s.settimeout(10)
    t = time.time()
    s.connect((host, port))
    ms = round((time.time()-t)*1000, 1)
    print(f'  \033[32m✓ TCP connected in {ms}ms\033[0m')
    s.close()
except socket.timeout:
    print(f'  \033[31m✗ TIMEOUT — port {port} blocked by ТСПУ or firewall\033[0m')
except ConnectionRefusedError:
    print(f'  \033[31m✗ CONNECTION REFUSED — nothing listening on port {port}\033[0m')
except Exception as e:
    print(f'  \033[31m✗ {e}\033[0m')
" 2>/dev/null
echo ""

# ============================================================
# [3/9] ТСПУ DEGRADATION — LATENCY HOLD TEST
# ============================================================
echo -e "${BLUE}[3/$TOTAL] ТСПУ degradation — latency hold test (25 sec)${NC}"
info "ТСПУ Stage 1: DPI drops packets → TCP retransmit → latency rises"
info "Classic symptom: wsarecv / forcibly closed at ~19 seconds"
echo ""

HOLD_SCRIPT="/tmp/hold_client_$$.py"
cat > "$HOLD_SCRIPT" << 'PYEOF'
import socket, time, sys

host = sys.argv[1]
port = int(sys.argv[2])

# Measure baseline latency
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
    except: pass

if not baselines:
    print("  \033[31m✗ Cannot connect — server unreachable\033[0m")
    sys.exit(1)

baseline = round(sum(baselines)/len(baselines), 1)
print(f"  Baseline latency : {baseline}ms")

try:
    s = socket.socket()
    s.settimeout(5)
    s.connect((host, port))
    s.settimeout(30)

    start     = time.time()
    drop_time = None
    samples   = []
    last_samp = start

    print(f"  Holding connection for 25 sec, sampling latency every 5s...")

    while time.time() - start < 25:
        time.sleep(0.5)
        elapsed = round(time.time() - start, 1)

        # Latency sample every 5 seconds
        if time.time() - last_samp >= 5:
            try:
                t2 = socket.socket()
                t2.settimeout(3)
                ts = time.time()
                t2.connect((host, port))
                lat = round((time.time()-ts)*1000, 1)
                t2.close()
                drift = lat - baseline
                samples.append((elapsed, lat))
                flag = ""
                if drift > 300:   flag = f" \033[31m← HIGH (ТСПУ Stage 1?)\033[0m"
                elif drift > 100: flag = f" \033[33m← elevated\033[0m"
                print(f"    t+{elapsed:4.1f}s  {lat}ms  drift={drift:+.0f}ms{flag}")
                last_samp = time.time()
            except: pass

        # Check if held connection dropped
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
    held = round(time.time() - start, 1)

    print()
    if drop_time is not None:
        if 14 <= drop_time <= 24:
            print(f"  \033[31m✗ DROPPED at {drop_time}s — ТСПУ 19-second DPI signature!\033[0m")
            print(f"    Matches: wsarecv / forcibly closed by remote host")
            print(f"    Fix: enable telemt TCP Splice or Reality on server")
        else:
            print(f"  \033[33m⚠ Dropped at {drop_time}s (not typical ТСПУ 19s pattern)\033[0m")
    else:
        print(f"  \033[32m✓ Connection held {held}s — no forced drop\033[0m")

    if samples:
        lats = [l for _, l in samples]
        max_drift = round(max(lats) - baseline, 1)
        if max_drift > 300:
            print(f"  \033[31m✗ Max drift: +{max_drift}ms — ТСПУ packet dropping (Stage 1)\033[0m")
        elif max_drift > 100:
            print(f"  \033[33m⚠ Max drift: +{max_drift}ms — elevated, may indicate throttling\033[0m")
        else:
            print(f"  \033[32m✓ Max drift: +{max_drift}ms — latency stable\033[0m")

except Exception as e:
    print(f"  \033[31m✗ Test error: {e}\033[0m")
PYEOF

python3 "$HOLD_SCRIPT" "$SERVER_IP" "$SERVER_PORT"
rm -f "$HOLD_SCRIPT"
echo ""

# ============================================================
# [4/9] TLS HANDSHAKE — TCP SPLICE CHECK
# ============================================================
echo -e "${BLUE}[4/$TOTAL] TLS handshake — TCP Splice verification${NC}"
info "With telemt TCP Splice: scanner gets REAL cert from mask domain"
info "With plain FakeTLS (ee): scanner may get fake/no cert → detectable"
echo ""

if command -v openssl &>/dev/null; then
    TLS=$(echo "Q" | timeout 8 openssl s_client \
        -connect "${SERVER_IP}:${SERVER_PORT}" \
        -servername "www.bing.com" \
        2>&1)

    CERT_CN=$(echo "$TLS"     | grep -oP "CN\s*=\s*\K[^\n,]+" | head -1)
    CERT_ISSUER=$(echo "$TLS" | grep "issuer" | head -1)
    VERIFY=$(echo "$TLS"      | grep "Verify return code" | head -1)

    # OpenSSL 1.x: "SSL certificate verify ok"
    # OpenSSL 3.x: "Verify return code: 0 (ok)"
    if echo "$TLS" | grep -qE "SSL certificate verify ok|Verify return code: 0 .ok."; then
        ok "Real TLS — certificate verified (TCP Splice working)"
        info "  CN     : ${CERT_CN:-?}"
        [ -n "$CERT_ISSUER" ] && info "  ${CERT_ISSUER}" | cut -c1-70
        [ -n "$VERIFY"      ] && info "  ${VERIFY}"
        ok "DPI cannot distinguish this from real HTTPS"
    elif echo "$TLS" | grep -q "CONNECTED"; then
        warn "TLS connected but verification inconclusive"
        [ -n "$CERT_CN" ] && info "  CN: $CERT_CN"
        [ -n "$VERIFY"  ] && info "  $VERIFY"
        info "  Manual: openssl s_client -connect ${SERVER_IP}:${SERVER_PORT} -servername www.bing.com"
    elif echo "$TLS" | grep -qiE "refused|reset|EINVAL"; then
        warn "No TLS response — check telemt config on server"
        info "  Expected: real cert from mask domain (GlobalSign, DigiCert, etc.)"
    else
        warn "Inconclusive TLS result"
        info "  Manual: openssl s_client -connect ${SERVER_IP}:${SERVER_PORT} -servername www.bing.com"
    fi
else
    warn "openssl not available — skipping"
fi
echo ""

# ============================================================
# [5/9] MTPROXY SECRET FORMAT
# ============================================================
echo -e "${BLUE}[5/$TOTAL] MTProxy secret format check${NC}"
if [ -n "$SECRET" ]; then
    python3 -c "
import sys
secret = '$SECRET'.strip()
print(f'  Secret : {secret[:8]}...{secret[-4:]}')
print(f'  Length : {len(secret)} chars')

if secret.startswith('ee') and len(secret) > 34:
    raw  = secret[2:34]
    dhex = secret[34:]
    try:
        domain = bytes.fromhex(dhex).decode('ascii')
        print(f'  \033[32m✓ FakeTLS (ee) secret\033[0m')
        print(f'    Raw secret  : {raw}')
        print(f'    SNI domain  : {domain}')
        print(f'    Best mode for ТСПУ bypass')
        # Verify domain reachability
        import socket
        try:
            ip = socket.gethostbyname(domain)
            print(f'    \033[32m✓ Domain resolves: {domain} → {ip}\033[0m')
        except:
            print(f'    \033[33m⚠ Domain does not resolve: {domain}\033[0m')
    except:
        print(f'  \033[31m✗ ee-prefix but invalid domain hex\033[0m')
elif secret.startswith('dd') and len(secret) == 34:
    print(f'  \033[33m⚠ DD-secret (obfuscation) — detectable by modern ТСПУ DPI\033[0m')
    print(f'    Recommend: migrate to ee (FakeTLS) secret')
elif len(secret) == 32:
    try:
        bytes.fromhex(secret)
        print(f'  \033[31m✗ Plain secret (no obfuscation) — easily detected by DPI\033[0m')
        print(f'    Recommend: migrate to telemt with ee secret')
    except:
        print(f'  \033[31m✗ Not valid hex\033[0m')
else:
    print(f'  \033[31m✗ Unknown format\033[0m')
    print(f'    Valid: ee + 32hex + domain_hex  (FakeTLS/telemt)')
" 2>/dev/null
else
    info "Skipped — pass secret as 3rd argument: bash $0 $SERVER_IP $SERVER_PORT YOUR_SECRET"
fi
echo ""

# ============================================================
# [6/9] DNS RESOLUTION
# ============================================================
echo -e "${BLUE}[6/$TOTAL] DNS resolution (client side)${NC}"
for DOMAIN in youtube.com google.com telegram.org cloudflare.com; do
    START=$(date +%s%3N)
    RESULT=$(python3 -c "
import socket
try:    print(socket.gethostbyname('$DOMAIN'))
except Exception as e: print('FAILED: ' + str(e))
" 2>/dev/null)
    END=$(date +%s%3N)
    MS=$((END - START))
    if echo "$RESULT" | grep -q "FAILED"; then
        fail "$DOMAIN — FAILED (DNS blocked or broken)"
    elif [ $MS -gt 2000 ]; then
        warn "$DOMAIN → $RESULT (${MS}ms — slow, will cause proxy DNS timeouts)"
    else
        ok "$DOMAIN → $RESULT (${MS}ms)"
    fi
done
echo ""

# ============================================================
# [7/9] TRACEROUTE — where packets drop
# ============================================================
echo -e "${BLUE}[7/$TOTAL] Route to server (traceroute)${NC}"
info "Looking for where packets get dropped..."
echo ""

TRACE_CMD=""
command -v traceroute &>/dev/null && TRACE_CMD="traceroute -m 20 -w 2 -n"
[ -z "$TRACE_CMD" ] && [ -x /usr/sbin/traceroute ] && TRACE_CMD="/usr/sbin/traceroute -m 20 -w 2 -n"
command -v tracepath  &>/dev/null && [ -z "$TRACE_CMD" ] && TRACE_CMD="tracepath -n -m 20"

if [ -n "$TRACE_CMD" ]; then
    $TRACE_CMD "$SERVER_IP" 2>/dev/null | while IFS= read -r line; do
        if echo "$line" | grep -qE '^\s*[0-9]+\s+\*\s+\*\s+\*'; then
            echo -e "  ${YELLOW}$line  ← packet lost here${NC}"
        else
            echo "  $line"
        fi
    done
    echo ""
    info "Interpretation:"
    info "  Drops at hops 1-3   → local network / ISP"
    info "  Drops at hops 4-8   → transit / backbone (often ТСПУ-related)"
    info "  Drops at hops 9+    → near-server routing"
    info "  No drops, connected → route is clean"
else
    warn "traceroute not found — TTL probe fallback:"
    PROBE_SCRIPT="/tmp/ttl_probe_$$.py"
    cat > "$PROBE_SCRIPT" << 'PYEOF'
import socket, time, sys
host, port = sys.argv[1], int(sys.argv[2])
for ttl in [1,2,3,5,8,12,16,20,30,64]:
    try:
        s = socket.socket()
        s.setsockopt(socket.IPPROTO_IP, socket.IP_TTL, ttl)
        s.settimeout(2)
        t = time.time()
        s.connect((host, port))
        ms = round((time.time()-t)*1000, 1)
        print(f"  TTL={ttl:2d}: connected in {ms}ms ✓ (~{ttl} hops)")
        s.close()
        break
    except socket.timeout:
        print(f"  TTL={ttl:2d}: timeout")
    except ConnectionRefusedError:
        print(f"  TTL={ttl:2d}: refused at ~hop {ttl}")
        break
    except Exception as e:
        print(f"  TTL={ttl:2d}: {e}")
PYEOF
    python3 "$PROBE_SCRIPT" "$SERVER_IP" "$SERVER_PORT"
    rm -f "$PROBE_SCRIPT"
fi
echo ""

# ============================================================
# [8/9] TCP LATENCY & JITTER
# ============================================================
echo -e "${BLUE}[8/$TOTAL] TCP latency & jitter (10 samples)${NC}"

JITTER_SCRIPT="/tmp/jitter_$$.py"
cat > "$JITTER_SCRIPT" << 'PYEOF'
import socket, time, sys
host, port = sys.argv[1], int(sys.argv[2])
samples = []

for i in range(10):
    try:
        s = socket.socket()
        s.settimeout(5)
        t = time.time()
        s.connect((host, port))
        samples.append(round((time.time()-t)*1000, 1))
        s.close()
        time.sleep(0.3)
    except:
        samples.append(None)

valid  = [x for x in samples if x is not None]
failed = len(samples) - len(valid)

if not valid:
    print("  \033[31m✗ All connections failed\033[0m")
    sys.exit()

avg    = round(sum(valid)/len(valid), 1)
mn     = min(valid)
mx     = max(valid)
jitter = round(mx - mn, 1)

print(f"  Samples : {len(valid)}/10 ok, {failed} failed")
print(f"  Latency : min={mn}ms  avg={avg}ms  max={mx}ms")
print(f"  Jitter  : {jitter}ms")
print()

# Failures
if failed > 2:
    print(f"  \033[31m✗ {failed} dropped connections — ТСПУ interference likely\033[0m")
elif failed > 0:
    print(f"  \033[33m⚠ {failed} failed connection(s) — minor instability\033[0m")

# Jitter thresholds — tighter than before (telemt should be stable)
if jitter > 200:
    print(f"  \033[31m✗ High jitter ({jitter}ms) — ТСПУ packet drops causing retransmits\033[0m")
elif jitter > 50:
    print(f"  \033[33m⚠ Moderate jitter ({jitter}ms) — may affect video/voice\033[0m")
else:
    print(f"  \033[32m✓ Stable jitter ({jitter}ms)\033[0m")

# Latency rating
if avg > 400:
    print(f"  \033[31m✗ Very high latency ({avg}ms) — server far away or throttled\033[0m")
elif avg > 200:
    print(f"  \033[33m⚠ High latency ({avg}ms) — distant server\033[0m")
elif avg > 80:
    print(f"  \033[32m✓ Normal latency ({avg}ms) — intercontinental route\033[0m")
else:
    print(f"  \033[32m✓ Good latency ({avg}ms)\033[0m")
PYEOF

python3 "$JITTER_SCRIPT" "$SERVER_IP" "$SERVER_PORT"
rm -f "$JITTER_SCRIPT"
echo ""

# ============================================================
# [9/9] SUMMARY
# ============================================================
echo -e "${BLUE}[9/$TOTAL] Summary${NC}"
echo ""

TCP_OK=$(python3 -c "
import socket, sys
try:
    s = socket.socket()
    s.settimeout(5)
    s.connect(('$SERVER_IP', $SERVER_PORT))
    s.close()
    print('1')
except:
    print('0')
" 2>/dev/null)

if [ "$TCP_OK" = "1" ]; then
    ok "Server ${SERVER_IP}:${SERVER_PORT} is reachable from this client"
else
    fail "Server ${SERVER_IP}:${SERVER_PORT} is NOT reachable"
    info "  Possible causes:"
    info "  - ТСПУ blocking this IP:port"
    info "  - Server firewall (ufw) not allowing port $SERVER_PORT"
    info "  - Proxy process not running on server"
fi

echo ""
echo "============================================================"
echo -e "${CYAN} Symptom → Check mapping${NC}"
echo "============================================================"
echo " TCP timeout / refused         → [2] basic connectivity"
echo " Latency rises after connect   → [3] hold test drift"
echo " Drops at ~19 seconds          → [3] hold test drop_time"
echo " No real cert from server      → [4] TLS / TCP Splice"
echo " Invalid or plain MTProxy key  → [5] secret format"
echo " DNS errors inside tunnel      → [6] DNS resolution"
echo " Packets lost mid-route        → [7] traceroute"
echo " Slow downloads / video stutter→ [8] jitter"
echo ""
echo -e "${CYAN} ТСПУ blocking stages:${NC}"
echo " Stage 1: DPI detects protocol → latency rises (drift +200ms+)"
echo " Stage 2: IP:port blocklisted  → connection timeout/refused"
echo " telemt TCP Splice makes Stage 1 detection significantly harder"
echo ""
echo -e "${CYAN} Manual checks:${NC}"
echo " Port test : https://check-host.net/check-tcp#${SERVER_IP}:${SERVER_PORT}"
echo " IP info   : https://bgp.he.net/ip/${SERVER_IP}"
echo "============================================================"
echo ""
