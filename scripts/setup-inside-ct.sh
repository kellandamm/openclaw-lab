#!/usr/bin/env bash
# ============================================================
# OpenClaw — Container Setup + Hardening
# Runs INSIDE the Debian 13 LXC container.
#
# Usage:
#   # Standalone (already have an LXC):
#   bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_REPO/openclaw-proxmox/main/setup-inside-ct.sh)
#
#   # With alert channel:
#   bash setup-inside-ct.sh --alert-webhook "https://hook.make.com/YOUR_HOOK"
#   bash setup-inside-ct.sh --alert-telegram "BOT_TOKEN" "CHAT_ID"
#
# Called automatically by install.sh — args are forwarded.
# ============================================================

set -euo pipefail

# ── Args ─────────────────────────────────────────────────────
ALERT_WEBHOOK=""
ALERT_TELEGRAM_TOKEN=""
ALERT_TELEGRAM_CHAT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --alert-webhook)   ALERT_WEBHOOK="$2";          shift 2 ;;
    --alert-telegram)  ALERT_TELEGRAM_TOKEN="$2";
                       ALERT_TELEGRAM_CHAT="$3";    shift 3 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Helpers ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}=== $* ===${NC}\n"; }

# ── Preflight ────────────────────────────────────────────────
[[ $(id -u) -eq 0 ]] || error "Run as root inside the container."
command -v systemctl &>/dev/null || error "systemd is required."

# Paths — defined once, used everywhere
OPENCLAW_DIR="/root/.openclaw"
CONFIG_FILE="${OPENCLAW_DIR}/openclaw.json"
BACKUP_DIR="/var/backups/openclaw"
SCRIPTS_DIR="/usr/local/lib/openclaw"
LOG_DIR="/var/log/openclaw"

# ═══════════════════════════════════════════════════════════════
#  PART 1 — INSTALL
# ═══════════════════════════════════════════════════════════════

# ── 1. Base packages ─────────────────────────────────────────
header "1/9  System packages"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
  ca-certificates curl gnupg git sudo \
  build-essential jq dbus-user-session \
  procps lsof net-tools ufw \
  fail2ban python3 openssl \
  chromium chromium-driver

success "Base packages installed."

# ── 2. Node.js 24 ────────────────────────────────────────────
header "2/9  Node.js 24"

if ! command -v node &>/dev/null || \
   [[ $(node -e 'process.stdout.write(process.version.split(".")[0].slice(1))' 2>/dev/null) -lt 22 ]]; then
  curl -fsSL https://deb.nodesource.com/setup_24.x | bash - 2>&1 | tail -5
  apt-get install -y -qq nodejs
fi

success "Node $(node -v), npm $(npm -v)"

# ── 3. OpenClaw ──────────────────────────────────────────────
header "3/9  OpenClaw"

npm install -g openclaw@latest --silent

OPENCLAW_VER=$(openclaw --version 2>/dev/null || echo "unknown")
OPENCLAW_BIN=$(which openclaw)
success "OpenClaw ${OPENCLAW_VER} installed at ${OPENCLAW_BIN}"

# ── 4. Config ────────────────────────────────────────────────
header "4/9  Config + service user"

if ! id -u openclaw &>/dev/null; then
  useradd -m -s /bin/bash openclaw
fi
NPM_GLOBAL_BIN="$(npm root -g)/../bin"
grep -q "openclaw_npm" /home/openclaw/.bashrc 2>/dev/null || \
  echo "export PATH=\"\$PATH:${NPM_GLOBAL_BIN}\" # openclaw_npm" >> /home/openclaw/.bashrc

GATEWAY_TOKEN=$(openssl rand -hex 32)
mkdir -p "$OPENCLAW_DIR"
chmod 700 "$OPENCLAW_DIR"

cat > "$CONFIG_FILE" <<CONFIGEOF
{
  "gateway": {
    "bind": "lan",
    "port": 18789,
    "auth": {
      "mode": "token",
      "token": "${GATEWAY_TOKEN}"
    }
  },
  "agent": {
    "model": "anthropic/claude-opus-4-6"
  },
  "channels": {
    "webchat": {
      "enabled": true
    }
  }
}
CONFIGEOF

chmod 600 "$CONFIG_FILE"
echo "$GATEWAY_TOKEN" > "${OPENCLAW_DIR}/.gateway-token"
chmod 600 "${OPENCLAW_DIR}/.gateway-token"

success "Config written → ${CONFIG_FILE}"

# ── 5. systemd service ───────────────────────────────────────
header "5/9  systemd service"

cat > /etc/systemd/system/openclaw.service <<SERVICEEOF
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment=HOME=/root
ExecStart=${OPENCLAW_BIN} gateway run
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICEEOF

systemctl daemon-reload
systemctl enable openclaw --quiet
systemctl start openclaw
sleep 4

if systemctl is-active --quiet openclaw; then
  success "openclaw.service running."
else
  warn "Service may still be initializing — check: journalctl -u openclaw -n 30"
fi

# ── 6. Firewall ──────────────────────────────────────────────
header "6/9  Firewall (ufw)"

ufw --force reset    >/dev/null
ufw default deny incoming  >/dev/null
ufw default allow outgoing >/dev/null
ufw allow ssh        >/dev/null
ufw allow 18789/tcp comment 'OpenClaw Gateway (LAN)' >/dev/null
ufw --force enable   >/dev/null

success "ufw enabled — SSH + 18789 open, everything else blocked."

# ── 7. Tailscale ─────────────────────────────────────────────
header "7/9  Tailscale"

if ! command -v tailscale &>/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh 2>&1 | tail -3 || \
    warn "Tailscale install failed — install manually later."
fi

if command -v tailscale &>/dev/null; then
  success "Tailscale installed. Run 'tailscale up' to authenticate."
else
  warn "Tailscale unavailable. Use SSH tunnel for remote access."
fi

# ═══════════════════════════════════════════════════════════════
#  PART 2 — HARDENING
# ═══════════════════════════════════════════════════════════════

mkdir -p "$BACKUP_DIR" "$SCRIPTS_DIR" "$LOG_DIR"
chmod 700 "$BACKUP_DIR"

header "8/9  Hardening (git · backup · watchdog · auto-update)"

# — Git-tracked config ————————————————————————————————————
if [[ ! -d "${OPENCLAW_DIR}/.git" ]]; then
  cd "$OPENCLAW_DIR"
  git init -q
  git config user.email "openclaw@localhost"
  git config user.name  "OpenClaw"
  cat > .gitignore <<'GITEOF'
logs/
sessions/
.gateway-token
credentials/
*.log
*.tmp
GITEOF
  git add openclaw.json .gitignore
  git commit -q -m "Initial config snapshot"
  cd - >/dev/null
fi

cat > "${SCRIPTS_DIR}/config-commit.sh" <<'COMMITEOF'
#!/usr/bin/env bash
cd /root/.openclaw
if ! git diff --quiet openclaw.json 2>/dev/null; then
  git add openclaw.json
  git commit -q -m "Config update $(date '+%Y-%m-%d %H:%M')"
fi
COMMITEOF
chmod +x "${SCRIPTS_DIR}/config-commit.sh"
echo "0 * * * * root ${SCRIPTS_DIR}/config-commit.sh >> ${LOG_DIR}/config-git.log 2>&1" \
  > /etc/cron.d/openclaw-config-git

success "Git config tracking — hourly commits to ${OPENCLAW_DIR}/.git"

# — Encrypted backup ——————————————————————————————————————
BACKUP_KEY_FILE="/root/.openclaw-backup.key"
if [[ ! -f "$BACKUP_KEY_FILE" ]]; then
  openssl rand -hex 32 > "$BACKUP_KEY_FILE"
  chmod 600 "$BACKUP_KEY_FILE"
fi

cat > "${SCRIPTS_DIR}/backup.sh" <<'BACKUPEOF'
#!/usr/bin/env bash
set -euo pipefail
OPENCLAW_DIR="/root/.openclaw"
BACKUP_DIR="/var/backups/openclaw"
KEY_FILE="/root/.openclaw-backup.key"
LOG_FILE="/var/log/openclaw/backup.log"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
ARCHIVE="/tmp/openclaw-backup-${TIMESTAMP}.tar.gz"
ENCRYPTED="${BACKUP_DIR}/openclaw-backup-${TIMESTAMP}.tar.gz.enc"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log "Starting backup..."

[[ -d "${OPENCLAW_DIR}/.git" ]] && {
  cd "$OPENCLAW_DIR"
  git add -A && git commit -q -m "Pre-backup $(date '+%Y-%m-%d %H:%M')" 2>/dev/null || true
  cd - >/dev/null
}

tar -czf "$ARCHIVE" \
  --exclude="${OPENCLAW_DIR}/logs" \
  --exclude="${OPENCLAW_DIR}/sessions" \
  --exclude="${OPENCLAW_DIR}/*.log" \
  "$OPENCLAW_DIR" 2>/dev/null

openssl enc -aes-256-cbc -pbkdf2 -pass "file:${KEY_FILE}" \
  -in "$ARCHIVE" -out "$ENCRYPTED"
rm -f "$ARCHIVE"

log "Backup complete: ${ENCRYPTED} ($(du -sh "$ENCRYPTED" | cut -f1))"
find "$BACKUP_DIR" -name "openclaw-backup-*.enc" -mtime +14 -delete
log "Rotation done. $(find "$BACKUP_DIR" -name '*.enc' | wc -l) backups retained."
BACKUPEOF
chmod +x "${SCRIPTS_DIR}/backup.sh"
echo "0 2 * * * root ${SCRIPTS_DIR}/backup.sh" > /etc/cron.d/openclaw-backup

success "Encrypted backup — daily 2 AM, AES-256, 14-day rotation → ${BACKUP_DIR}"

# — Health watchdog ———————————————————————————————————————
# Resolve gateway port now so the watchdog script has it baked in
GATEWAY_PORT=$(python3 -c "
import json
try:
  c = json.load(open('${CONFIG_FILE}'))
  print(c.get('gateway', {}).get('port', 18789))
except: print(18789)
" 2>/dev/null || echo 18789)

# Build the send_alert() body based on which channels were provided
_alert_body=""
if [[ -n "$ALERT_WEBHOOK" ]]; then
  _alert_body+="  curl -sf -X POST '${ALERT_WEBHOOK}' \\"$'\n'
  _alert_body+="    -H 'Content-Type: application/json' \\"$'\n'
  _alert_body+='    -d "{\"subject\":\"\${subject}\",\"body\":\"\${body}\",\"level\":\"\${level}\",\"host\":\"\$(hostname)\"}" \\'$'\n'
  _alert_body+="    >/dev/null 2>&1 || true"$'\n'
fi
if [[ -n "$ALERT_TELEGRAM_TOKEN" && -n "$ALERT_TELEGRAM_CHAT" ]]; then
  _alert_body+="  local emoji='⚠️'; [[ \"\${level}\" == 'ok' ]] && emoji='✅'"$'\n'
  _alert_body+="  curl -sf 'https://api.telegram.org/bot${ALERT_TELEGRAM_TOKEN}/sendMessage' \\"$'\n'
  _alert_body+="    -d 'chat_id=${ALERT_TELEGRAM_CHAT}' \\"$'\n'
  _alert_body+='    -d "text=${emoji} *OpenClaw ($(hostname))*%0A${subject}%0A${body}" \\'$'\n'
  _alert_body+="    -d 'parse_mode=Markdown' >/dev/null 2>&1 || true"$'\n'
fi
if [[ -z "$_alert_body" ]]; then
  _alert_body="  true  # no alert channel configured"$'\n'
fi

cat > "${SCRIPTS_DIR}/watchdog.sh" <<WATCHDOGEOF
#!/usr/bin/env bash
set -euo pipefail
GATEWAY_PORT="${GATEWAY_PORT}"
GATEWAY_TOKEN="\$(cat /root/.openclaw/.gateway-token 2>/dev/null || echo '')"
LOG_FILE="/var/log/openclaw/watchdog.log"
STATE_FILE="/tmp/openclaw-watchdog-state"
MAX_RESTARTS=3
RESTART_WINDOW=300

log() { echo "\$(date '+%Y-%m-%d %H:%M:%S') \$*" | tee -a "\$LOG_FILE"; }

send_alert() {
  local subject="\$1" body="\$2" level="\${3:-warn}"
${_alert_body}}

check_health() {
  local code
  code=\$(curl -sf -o /dev/null -w "%{http_code}" \\
    -H "Authorization: Bearer \${GATEWAY_TOKEN}" \\
    "http://127.0.0.1:\${GATEWAY_PORT}/health" \\
    --max-time 10 2>/dev/null || echo "000")
  [[ "\$code" == "200" ]]
}

recent_restarts() {
  [[ -f "\$STATE_FILE" ]] || { echo 0; return; }
  local cutoff=\$(( \$(date +%s) - RESTART_WINDOW ))
  awk -v c="\$cutoff" '\$1 > c { n++ } END { print n+0 }' "\$STATE_FILE"
}

record_restart() {
  date +%s >> "\$STATE_FILE"
  tail -20 "\$STATE_FILE" > "\${STATE_FILE}.tmp" && mv "\${STATE_FILE}.tmp" "\$STATE_FILE"
}

if check_health; then
  if [[ -f /tmp/openclaw-was-down ]]; then
    log "Gateway recovered."
    send_alert "Gateway recovered ✅" "OpenClaw is healthy again on \$(hostname)." "ok"
    rm -f /tmp/openclaw-was-down
  fi
  exit 0
fi

log "Health check FAILED on port \${GATEWAY_PORT}."
touch /tmp/openclaw-was-down

RECENT=\$(recent_restarts)
if [[ "\$RECENT" -ge "\$MAX_RESTARTS" ]]; then
  log "Restart limit hit (\${MAX_RESTARTS} in \$(( RESTART_WINDOW / 60 )) min). Manual action needed."
  send_alert "Gateway down — restart limit reached 🚨" \\
    "Failed \${MAX_RESTARTS}+ times. Check: journalctl -u openclaw -n 50" "warn"
  exit 1
fi

log "Restarting (recent restarts in window: \${RECENT})..."
record_restart
systemctl restart openclaw
sleep 5

if check_health; then
  log "Restart successful."
  send_alert "Gateway restarted ⚠️" "OpenClaw was down and has been auto-restarted on \$(hostname)." "warn"
else
  log "Restart FAILED — gateway still unhealthy."
  send_alert "Gateway restart FAILED 🚨" \\
    "Still down after restart on \$(hostname). Check: journalctl -u openclaw -n 50" "warn"
  exit 1
fi
WATCHDOGEOF

chmod +x "${SCRIPTS_DIR}/watchdog.sh"
echo "*/5 * * * * root ${SCRIPTS_DIR}/watchdog.sh" > /etc/cron.d/openclaw-watchdog

if [[ -n "$ALERT_WEBHOOK" ]]; then
  success "Watchdog — every 5 min, alerts via Make.com webhook"
elif [[ -n "$ALERT_TELEGRAM_TOKEN" ]]; then
  success "Watchdog — every 5 min, alerts via Telegram"
else
  success "Watchdog — every 5 min (log only, no alert channel set)"
fi

# — Auto-update with rollback ————————————————————————————
cat > "${SCRIPTS_DIR}/update.sh" <<'UPDATEEOF'
#!/usr/bin/env bash
set -euo pipefail
LOG_FILE="/var/log/openclaw/update.log"
SCRIPTS_DIR="/usr/local/lib/openclaw"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }

check_health() {
  local token port code
  token=$(cat /root/.openclaw/.gateway-token 2>/dev/null || echo "")
  port=$(python3 -c "
import json
c = json.load(open('/root/.openclaw/openclaw.json'))
print(c.get('gateway', {}).get('port', 18789))
" 2>/dev/null || echo 18789)
  code=$(curl -sf -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${token}" \
    "http://127.0.0.1:${port}/health" \
    --max-time 15 2>/dev/null || echo "000")
  [[ "$code" == "200" ]]
}

CURRENT=$(openclaw --version 2>/dev/null || echo "unknown")
LATEST=$(npm view openclaw version 2>/dev/null || echo "unknown")

if [[ "$CURRENT" == "$LATEST" ]]; then
  log "Already up to date (${CURRENT}). Nothing to do."
  exit 0
fi

log "Update available: ${CURRENT} → ${LATEST}"

[[ -d "/root/.openclaw/.git" ]] && {
  cd /root/.openclaw
  git add -A && git commit -q -m "Pre-update snapshot: ${CURRENT}" 2>/dev/null || true
  cd - >/dev/null
}

log "Creating pre-update backup..."
"${SCRIPTS_DIR}/backup.sh" >> "$LOG_FILE" 2>&1

log "Stopping service for update..."
systemctl stop openclaw
npm install -g "openclaw@${LATEST}" --silent >> "$LOG_FILE" 2>&1
systemctl start openclaw
sleep 8

if check_health; then
  log "Update successful: ${CURRENT} → ${LATEST}"
  [[ -d "/root/.openclaw/.git" ]] && {
    cd /root/.openclaw
    git add -A && git commit -q -m "Post-update: ${LATEST}" 2>/dev/null || true
    cd - >/dev/null
  }
else
  log "Health check FAILED after update — rolling back to ${CURRENT}..."
  systemctl stop openclaw
  npm install -g "openclaw@${CURRENT}" --silent >> "$LOG_FILE" 2>&1
  systemctl start openclaw
  sleep 5
  if check_health; then
    log "Rollback to ${CURRENT} successful."
  else
    log "ROLLBACK ALSO FAILED — manual intervention required."
    exit 1
  fi
fi
UPDATEEOF

chmod +x "${SCRIPTS_DIR}/update.sh"
echo "0 3 * * 0 root ${SCRIPTS_DIR}/update.sh" > /etc/cron.d/openclaw-update

success "Auto-update — Sundays 3 AM, pre-backup + rollback on health failure"

# ── 9. SSH hardening ─────────────────────────────────────────
header "9/9  SSH hardening"

SSHD_CONFIG="/etc/ssh/sshd_config"
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%Y%m%d)"

apply_sshd() {
  local key="$1" val="$2"
  if grep -qE "^#?\s*${key}" "$SSHD_CONFIG"; then
    sed -i "s|^#*\s*${key}.*|${key} ${val}|" "$SSHD_CONFIG"
  else
    echo "${key} ${val}" >> "$SSHD_CONFIG"
  fi
}

apply_sshd "PermitRootLogin"        "prohibit-password"
apply_sshd "PasswordAuthentication" "no"
apply_sshd "PubkeyAuthentication"   "yes"
apply_sshd "X11Forwarding"          "no"
apply_sshd "MaxAuthTries"           "3"
apply_sshd "LoginGraceTime"         "30"
apply_sshd "ClientAliveInterval"    "300"
apply_sshd "ClientAliveCountMax"    "2"

if sshd -t 2>/dev/null; then
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  success "SSH hardened — key-only auth, no password login."
else
  warn "SSH config test failed. Restoring original."
  cp "${SSHD_CONFIG}.bak.$(date +%Y%m%d)" "$SSHD_CONFIG"
fi

cat > /etc/fail2ban/jail.d/openclaw-ssh.conf <<'F2BEOF'
[sshd]
enabled  = true
port     = ssh
maxretry = 5
bantime  = 3600
findtime = 600
F2BEOF
systemctl enable fail2ban --quiet
systemctl restart fail2ban
success "fail2ban enabled — SSH brute-force protection active."

# ═══════════════════════════════════════════════════════════════
#  SUMMARY
# ═══════════════════════════════════════════════════════════════

CT_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}  OpenClaw — Setup + Hardening Complete${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${BOLD}Dashboard:${NC}      http://${CT_IP}:18789"
echo -e "  ${BOLD}Gateway token:${NC}  ${GATEWAY_TOKEN}"
echo -e "  ${BOLD}Config:${NC}         ${CONFIG_FILE}"
echo ""
echo -e "  ${BOLD}Hardening installed:${NC}"
echo -e "  ${GREEN}✓${NC} Git config tracking    hourly commits → rollback anytime"
echo -e "                          git -C ${OPENCLAW_DIR} log --oneline"
echo -e "  ${GREEN}✓${NC} Encrypted backups      daily 2 AM → ${BACKUP_DIR}"
echo -e "                          restore: openssl enc -d -aes-256-cbc -pbkdf2 \\"
echo -e "                            -pass file:/root/.openclaw-backup.key \\"
echo -e "                            -in <file.enc> | tar -xz -C /"

if [[ -n "$ALERT_WEBHOOK" ]]; then
  echo -e "  ${GREEN}✓${NC} Health watchdog        every 5 min → Make.com webhook alerts"
elif [[ -n "$ALERT_TELEGRAM_TOKEN" ]]; then
  echo -e "  ${GREEN}✓${NC} Health watchdog        every 5 min → Telegram alerts"
else
  echo -e "  ${YELLOW}⚠${NC}  Health watchdog        every 5 min → ${YELLOW}log only, no alerts${NC}"
fi

echo -e "  ${GREEN}✓${NC} Auto-update            Sundays 3 AM → pre-backup + rollback"
echo -e "  ${GREEN}✓${NC} SSH hardened           key-only, fail2ban active"
echo ""

if [[ -z "$ALERT_WEBHOOK" && -z "$ALERT_TELEGRAM_TOKEN" ]]; then
  echo -e "  ${YELLOW}To add alerts later, re-run with a flag:${NC}"
  echo -e "  bash setup-inside-ct.sh --alert-webhook 'https://hook.make.com/YOUR_HOOK'"
  echo -e "  bash setup-inside-ct.sh --alert-telegram 'BOT_TOKEN' 'CHAT_ID'"
  echo ""
fi

echo -e "  ${YELLOW}⚠  Do these two things before logging out:${NC}"
echo -e "  1. Back up your encryption key:"
echo -e "     cat /root/.openclaw-backup.key"
echo -e "  2. Add your SSH public key (password auth is now disabled):"
echo -e "     ssh-copy-id root@${CT_IP}"
echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo "  1. openclaw onboard        — connect AI provider + messaging channels"
echo "  2. tailscale up            — authenticate for secure remote access"
echo "  3. tailscale serve 18789   — expose dashboard over Tailscale HTTPS"
echo ""
echo -e "  ${BOLD}Useful commands:${NC}"
echo "  systemctl status openclaw          journalctl -u openclaw -f"
echo "  ${SCRIPTS_DIR}/update.sh     ${SCRIPTS_DIR}/backup.sh"
echo "  ${SCRIPTS_DIR}/watchdog.sh   ${SCRIPTS_DIR}/config-commit.sh"
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
