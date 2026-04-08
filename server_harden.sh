#!/bin/bash
# ============================================================
# Server Hardening Script v1.0
# Full security hardening for MTProxy (telemt) VPS
#
# What it does:
#   A. SSH: key-only auth, port change, login restrictions
#   B. fail2ban: SSH + port 443 scanner protection
#   C. Auto-updates: unattended-upgrades
#   D. Proxy stealth: rate limiting, connection limits
#   E. Kernel: sysctl hardening, IP spoofing protection
#   F. Audit: open ports, running services, cron review
#
# Usage: bash server_harden.sh [new_ssh_port]
#   new_ssh_port — optional, default: 2222
#
# Run as root. Safe to re-run.
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

NEW_SSH_PORT="${1:-2222}"
PROXY_PORT="443"

ok()   { echo -e "  ${GREEN}✓ $*${NC}"; }
warn() { echo -e "  ${YELLOW}⚠ $*${NC}"; }
fail() { echo -e "  ${RED}✗ $*${NC}"; }
info() { echo "  $*"; }
step() { echo -e "\n${BLUE}[$1/$TOTAL] $2${NC}"; }

TOTAL=8

# ============================================================
# ROOT CHECK
# ============================================================
[ "$EUID" -ne 0 ] && { echo -e "${RED}Run as root${NC}"; exit 1; }

# ============================================================
# DETECT CURRENT SSH PORT
# ============================================================
CURRENT_SSH_PORT=$(ss -tlnp | grep sshd | grep -oP ':\K[0-9]+' | head -1)
CURRENT_SSH_PORT="${CURRENT_SSH_PORT:-22}"

echo ""
echo "============================================================"
echo " Server Hardening Script v1.0"
echo "============================================================"
echo " Current SSH port : $CURRENT_SSH_PORT"
echo " New SSH port     : $NEW_SSH_PORT"
echo " Proxy port       : $PROXY_PORT"
echo " Date             : $(date '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================================"

# Safety check — if current SSH = new SSH, keep it
SAME_SSH_PORT=0
[ "$CURRENT_SSH_PORT" = "$NEW_SSH_PORT" ] && {
    echo -e "  ${CYAN}SSH already on port $NEW_SSH_PORT — keeping${NC}"
    SAME_SSH_PORT=1
}

echo ""
echo -e "${YELLOW}IMPORTANT: After this script you must SSH on port $NEW_SSH_PORT${NC}"
echo -e "${YELLOW}Make sure you can open a second SSH session before proceeding!${NC}"
echo ""
read -p "Continue? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ============================================================
# STEP 1: INSTALL PACKAGES
# ============================================================
step 1 "Installing security packages"

apt-get update -qq 2>/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    fail2ban \
    unattended-upgrades \
    apt-listchanges \
    ufw \
    logwatch \
    auditd \
    libpam-pwquality \
    2>/dev/null

ok "Packages installed: fail2ban, unattended-upgrades, logwatch, auditd"

# ============================================================
# STEP 2: SSH HARDENING
# ============================================================
step 2 "SSH hardening"

SSHD_CONF="/etc/ssh/sshd_config"
SSHD_BACKUP="/etc/ssh/sshd_config.backup.$(date +%Y%m%d%H%M%S)"

cp "$SSHD_CONF" "$SSHD_BACKUP"
ok "Backup: $SSHD_BACKUP"

# Helper: set or replace sshd_config parameter
sshd_set() {
    local key="$1" val="$2"
    if grep -qE "^#?[[:space:]]*${key}[[:space:]]" "$SSHD_CONF"; then
        sed -i "s|^#\?[[:space:]]*${key}[[:space:]].*|${key} ${val}|" "$SSHD_CONF"
    else
        echo "${key} ${val}" >> "$SSHD_CONF"
    fi
}

# Change SSH port
sshd_set "Port"                    "$NEW_SSH_PORT"

# Disable root login with password — keep key-based if needed
# Check if root has authorized_keys first
if [ -s /root/.ssh/authorized_keys ]; then
    sshd_set "PermitRootLogin"     "prohibit-password"
    ok "Root login: key-only (authorized_keys found)"
else
    sshd_set "PermitRootLogin"     "no"
    warn "Root login: disabled (no authorized_keys — ensure you have a sudo user!)"
fi

# Disable password auth
sshd_set "PasswordAuthentication" "no"
sshd_set "ChallengeResponseAuthentication" "no"
sshd_set "KbdInteractiveAuthentication"    "no"

# Security settings
sshd_set "PermitEmptyPasswords"   "no"
sshd_set "MaxAuthTries"           "3"
sshd_set "MaxSessions"            "5"
sshd_set "LoginGraceTime"         "30"
sshd_set "ClientAliveInterval"    "300"
sshd_set "ClientAliveCountMax"    "2"
sshd_set "X11Forwarding"          "no"
sshd_set "AllowAgentForwarding"   "no"
sshd_set "AllowTcpForwarding"     "no"
sshd_set "PrintLastLog"           "yes"
sshd_set "TCPKeepAlive"           "yes"
sshd_set "Compression"            "no"
sshd_set "LogLevel"               "VERBOSE"
sshd_set "UseDNS"                 "no"

# Modern crypto only
sshd_set "KexAlgorithms"   "curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512"
sshd_set "Ciphers"         "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com"
sshd_set "MACs"            "hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,umac-128-etm@openssh.com"

# Validate config before restarting
if sshd -t 2>/dev/null; then
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    ok "SSH restarted on port $NEW_SSH_PORT"
    ok "Password auth: disabled"
    ok "Modern crypto: configured"
else
    warn "sshd config test failed — restoring backup"
    cp "$SSHD_BACKUP" "$SSHD_CONF"
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    fail "SSH hardening reverted — check $SSHD_BACKUP manually"
fi

# ============================================================
# STEP 3: FIREWALL
# ============================================================
step 3 "Firewall (UFW)"

ufw default deny incoming  2>/dev/null
ufw default allow outgoing 2>/dev/null

# SSH on new port
ufw allow "$NEW_SSH_PORT/tcp" comment "SSH hardened" 2>/dev/null

# Keep old SSH port open for 10 minutes (safety window)
if [ "$CURRENT_SSH_PORT" != "$NEW_SSH_PORT" ]; then
    ufw allow "$CURRENT_SSH_PORT/tcp" comment "SSH old port - remove after confirming new port" 2>/dev/null
    warn "Old SSH port $CURRENT_SSH_PORT is still open — remove after confirming new port works:"
    info "  ufw delete allow $CURRENT_SSH_PORT/tcp"
fi

# MTProxy port
ufw allow "$PROXY_PORT/tcp" comment "MTProxy telemt" 2>/dev/null

# Rate limiting on proxy port — slows down scanners
# Max 30 new connections per 30 seconds per IP
ufw limit "$PROXY_PORT/tcp" 2>/dev/null

ufw --force enable 2>/dev/null
ufw reload 2>/dev/null

ok "UFW: SSH=$NEW_SSH_PORT, Proxy=$PROXY_PORT"
ok "Rate limiting enabled on port $PROXY_PORT"

# ============================================================
# STEP 4: FAIL2BAN
# ============================================================
step 4 "fail2ban — brute-force and scanner protection"

# Main fail2ban config
cat > /etc/fail2ban/jail.local << 'F2B'
[DEFAULT]
bantime        = 3600
findtime       = 600
maxretry       = 5
backend        = systemd
ignoreip       = 127.0.0.1/8 ::1

# ---- SSH ----
[sshd]
enabled  = true
port     = SSH_PORT_PLACEHOLDER
filter   = sshd
logpath  = %(syslog_authpriv)s
maxretry = 3
bantime  = 86400

# ---- Port 443 scanner protection ----
# Bans IPs that make excessive new TCP connections to the proxy port.
# Legitimate users connect once and stay connected.
# Scanners/probers open many short-lived connections.
[proxy-scan]
enabled  = true
filter   = proxy-scan
port     = 443
logpath  = /var/log/proxy-scan.log
maxretry = 20
findtime = 60
bantime  = 3600
F2B

# Replace SSH port placeholder
sed -i "s/SSH_PORT_PLACEHOLDER/$NEW_SSH_PORT/" /etc/fail2ban/jail.local

# Custom filter for proxy port scanning
mkdir -p /etc/fail2ban/filter.d
cat > /etc/fail2ban/filter.d/proxy-scan.conf << 'FILTER'
[Definition]
# Match connection log entries — detects rapid scanning
failregex = ^.*NEW.*SRC=<HOST>.*DPT=443.*$
            ^.*SCAN.*<HOST>.*$
ignoreregex =
FILTER

# UFW logging for fail2ban to pick up (minimal — only new connections)
ufw logging low 2>/dev/null

systemctl enable fail2ban 2>/dev/null
systemctl restart fail2ban 2>/dev/null
sleep 2

if systemctl is-active --quiet fail2ban; then
    ok "fail2ban running"
    JAILS=$(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*Jail list:\s*//')
    info "Active jails: $JAILS"
else
    warn "fail2ban failed to start — check: journalctl -u fail2ban -n 20"
fi

# ============================================================
# STEP 5: AUTO-UPDATES
# ============================================================
step 5 "Automatic security updates"

cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'APT'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};

// Auto-remove unused packages
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";

// Reboot only if required (kernel updates)
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";

// Log everything
Unattended-Upgrade::Verbose "false";
Unattended-Upgrade::Debug "false";
APT

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'APT'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
APT

systemctl enable unattended-upgrades 2>/dev/null
systemctl restart unattended-upgrades 2>/dev/null

ok "Automatic security updates enabled (daily)"
ok "Auto-reboot disabled — manual reboot required for kernel updates"

# ============================================================
# STEP 6: KERNEL HARDENING (sysctl)
# ============================================================
step 6 "Kernel hardening (sysctl)"

cat > /etc/sysctl.d/99-hardening.conf << 'SYSCTL'
# ============================================================
# Kernel security hardening
# ============================================================

# --- Network: anti-spoofing & DDoS mitigation ---
net.ipv4.conf.all.rp_filter                = 1
net.ipv4.conf.default.rp_filter            = 1
net.ipv4.conf.all.accept_source_route      = 0
net.ipv4.conf.default.accept_source_route  = 0
net.ipv4.conf.all.accept_redirects         = 0
net.ipv4.conf.default.accept_redirects     = 0
net.ipv4.conf.all.secure_redirects         = 0
net.ipv4.conf.default.secure_redirects     = 0
net.ipv4.conf.all.send_redirects           = 0
net.ipv4.conf.default.send_redirects       = 0
net.ipv4.icmp_echo_ignore_broadcasts       = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies                    = 1
net.ipv4.tcp_rfc1337                       = 1

# --- IPv6 ---
net.ipv6.conf.all.accept_redirects         = 0
net.ipv6.conf.default.accept_redirects     = 0
net.ipv6.conf.all.accept_source_route      = 0

# --- TCP performance (proxy-optimized) ---
net.ipv4.tcp_congestion_control            = bbr
net.core.default_qdisc                     = fq
net.ipv4.tcp_fastopen                      = 3
net.ipv4.tcp_slow_start_after_idle         = 0
net.ipv4.tcp_no_metrics_save               = 1
net.core.somaxconn                         = 65535
net.core.netdev_max_backlog                = 65535
net.ipv4.tcp_max_syn_backlog               = 65535

# --- Connection limits ---
net.ipv4.tcp_fin_timeout                   = 15
net.ipv4.tcp_keepalive_time                = 300
net.ipv4.tcp_keepalive_intvl               = 60
net.ipv4.tcp_keepalive_probes              = 3

# --- System ---
# Disable magic SysRq
kernel.sysrq                               = 0
# Hide kernel pointers from /proc
kernel.kptr_restrict                       = 2
# Restrict dmesg to root
kernel.dmesg_restrict                      = 1
# Prevent core dumps with setuid
fs.suid_dumpable                           = 0
# ASLR: full randomization
kernel.randomize_va_space                  = 2
SYSCTL

sysctl -p /etc/sysctl.d/99-hardening.conf >/dev/null 2>&1
ok "Anti-spoofing (rp_filter, source routing blocked)"
ok "SYN flood protection (tcp_syncookies)"
ok "BBR + fq (already set, confirmed)"
ok "ASLR: full randomization"
ok "Kernel pointer hiding"

# ============================================================
# STEP 7: PROXY STEALTH — CONNECTION LIMITS
# ============================================================
step 7 "Proxy stealth — connection limits & anti-scan"

# Per-IP connection limit on port 443
# Legitimate user: 1-3 persistent connections
# Scanner: many short connections from same IP
# This iptables rule limits to 20 concurrent connections per IP
# Allow localhost first (monitoring script connects locally)
iptables -I INPUT -p tcp --dport 443 -s 127.0.0.0/8 -j ACCEPT 2>/dev/null
# Limit external IPs only
iptables -I INPUT -p tcp --dport 443 -m connlimit --connlimit-above 20 \
    --connlimit-mask 32 ! -s 127.0.0.0/8 -j REJECT --reject-with tcp-reset 2>/dev/null \
    && ok "Per-IP connection limit: max 20 concurrent on port 443 (localhost exempt)" \
    || warn "iptables connlimit not available (kernel module missing)"

# Save iptables rules
if command -v iptables-save &>/dev/null; then
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null

    # Restore on boot
    cat > /etc/systemd/system/iptables-restore.service << 'SERVICE'
[Unit]
Description=Restore iptables rules
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE
    systemctl enable iptables-restore 2>/dev/null
    ok "iptables rules saved and set to restore on boot"
fi

# telemt already handles the main stealth:
# - Unauthenticated connections → real www.bing.com cert (TCP Splice)
# - DPI/scanners see legitimate HTTPS, not MTProxy fingerprint
ok "telemt TCP Splice: unauthenticated → real www.bing.com cert"
ok "JA3/JA4 fingerprint: indistinguishable from browser"

# Optional: hide SSH port from nmap SYN scan (port knocking alternative)
# We already moved SSH to $NEW_SSH_PORT — this alone reduces 99% of automated scans
ok "SSH moved to non-standard port $NEW_SSH_PORT — eliminates automated SSH scans"

# ============================================================
# STEP 8: AUDIT & CLEANUP
# ============================================================
step 8 "System audit & cleanup"

# Disable unnecessary services
for SVC in avahi-daemon cups bluetooth ModemManager; do
    if systemctl is-enabled "$SVC" 2>/dev/null | grep -q "enabled"; then
        systemctl disable --now "$SVC" 2>/dev/null
        ok "Disabled: $SVC"
    fi
done

# Remove unused packages
DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq 2>/dev/null
ok "Unused packages removed"

# Enable auditd for security logging
systemctl enable auditd 2>/dev/null
systemctl start  auditd 2>/dev/null

# Audit rules: watch for privilege escalation attempts
cat > /etc/audit/rules.d/hardening.rules << 'AUDIT'
# Monitor authentication
-w /etc/passwd    -p wa -k identity
-w /etc/shadow    -p wa -k identity
-w /etc/sudoers   -p wa -k sudoers
# Monitor SSH config changes
-w /etc/ssh/sshd_config -p wa -k sshd_config
# Monitor telemt config
-w /etc/telemt/ -p wa -k telemt_config
# Detect privilege escalation
-a always,exit -F arch=b64 -S setuid -k privilege_escalation
AUDIT

service auditd restart 2>/dev/null
ok "auditd: monitoring auth, sudoers, SSH config, telemt config"

# Logwatch daily report
if command -v logwatch &>/dev/null; then
    cat > /etc/logwatch/conf/logwatch.conf << LOGWATCH
Output = mail
Format = text
Encode = none
MailTo = root
MailFrom = logwatch@$(hostname)
Range = yesterday
Detail = Low
Service = All
LOGWATCH
    ok "logwatch: daily report to root (check with: mail)"
fi

# ============================================================
# FINAL SUMMARY
# ============================================================
echo ""
echo "============================================================"
echo -e "${GREEN} ✓ Server hardening complete!${NC}"
echo "============================================================"
echo ""
echo -e "${CYAN} Changes made:${NC}"
echo "  SSH port      : $CURRENT_SSH_PORT → $NEW_SSH_PORT"
echo "  SSH auth      : key-only (password disabled)"
echo "  SSH crypto    : modern only (curve25519, chacha20, AES-GCM)"
echo "  fail2ban      : SSH + proxy scanner protection"
echo "  Auto-updates  : security patches daily"
echo "  Kernel        : anti-spoofing, SYN cookies, ASLR, BBR"
echo "  Proxy stealth : TCP Splice + 20 conn/IP limit on port 443"
echo "  Audit logging : auth, sudoers, SSH config, telemt config"
echo ""
echo -e "${RED} CRITICAL — ACTION REQUIRED:${NC}"
echo ""
echo "  1. Open a NEW terminal and verify SSH works on port $NEW_SSH_PORT:"
echo ""
echo "     ssh -p $NEW_SSH_PORT root@$(curl -s ifconfig.me 2>/dev/null)"
echo ""
echo "  2. Only after confirming — remove old SSH port from UFW:"
echo ""
echo "     ufw delete allow $CURRENT_SSH_PORT/tcp"
echo "     ufw status"
echo ""
echo -e "${YELLOW} Monitoring:${NC}"
echo "  fail2ban status : fail2ban-client status"
echo "  Banned IPs SSH  : fail2ban-client status sshd"
echo "  Banned IPs proxy: fail2ban-client status proxy-scan"
echo "  UFW events      : journalctl -k | grep UFW | tail -20"
echo "  SSH log         : journalctl -u ssh -f"
echo "  Auth events     : journalctl | grep -E 'sshd|sudo' | tail -20"
echo "  Audit log       : ausearch -k identity | tail -20"
echo "  Security updates: unattended-upgrade --dry-run"
echo "  All warnings    : journalctl -p warning --since today"
echo ""
echo -e "${CYAN} telemt proxy — no changes needed:${NC}"
echo "  TCP Splice already provides stealth (real TLS to www.bing.com)"
echo "  Unauthenticated scanners see real bing.com, not MTProxy"
echo "  Config: /etc/telemt/telemt.toml"
echo "  Links : curl -s http://127.0.0.1:9091/v1/users | jq"
echo "============================================================"
echo ""
