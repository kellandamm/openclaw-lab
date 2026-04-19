#!/usr/bin/env bash
# ============================================================
# OpenClaw Inner Setup Script
# Runs INSIDE the Debian 13 LXC container.
# Called automatically by install.sh — or run manually:
#   bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_REPO/openclaw-proxmox/main/setup-inside-ct.sh)
# ============================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}=== $* ===${NC}\n"; }

# ── Base packages ────────────────────────────────────────────
header "Updating system and installing dependencies"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
  ca-certificates curl gnupg git sudo \
  build-essential jq dbus-user-session \
  procps lsof net-tools ufw \
  chromium chromium-driver

success "Base packages installed."

# ── Node.js 24 ───────────────────────────────────────────────
header "Installing Node.js 24"

if ! command -v node &>/dev/null || [[ "$(node -e 'process.exit(parseInt(process.version.slice(1)) < 22 ? 1 : 0)' 2>/dev/null; echo $?)" -ne 0 ]]; then
  curl -fsSL https://deb.nodesource.com/setup_24.x | bash - 2>&1 | tail -5
  apt-get install -y -qq nodejs
fi

NODE_VER=$(node -v)
NPM_VER=$(npm -v)
success "Node ${NODE_VER}, npm ${NPM_VER}"

# ── OpenClaw ─────────────────────────────────────────────────
header "Installing OpenClaw"

npm install -g openclaw@latest --silent

OPENCLAW_VER=$(openclaw --version 2>/dev/null || echo "unknown")
success "OpenClaw ${OPENCLAW_VER} installed."

# ── Dedicated service user ───────────────────────────────────
header "Creating openclaw service user"

if ! id -u openclaw &>/dev/null; then
  useradd -m -s /bin/bash openclaw
fi

# Give openclaw access to npm global bin
OPENCLAW_BIN=$(npm root -g)/../bin
echo "export PATH=\"\$PATH:${OPENCLAW_BIN}\"" >> /home/openclaw/.bashrc

success "User 'openclaw' ready."

# ── Config skeleton ──────────────────────────────────────────
header "Writing initial openclaw.json"

GATEWAY_TOKEN=$(openssl rand -hex 32)
CONFIG_DIR=/root/.openclaw
mkdir -p "$CONFIG_DIR"

cat > "${CONFIG_DIR}/openclaw.json" <<EOF
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
EOF

chmod 600 "${CONFIG_DIR}/openclaw.json"
success "Config written to ${CONFIG_DIR}/openclaw.json"

# Store token for the outer script to read
echo "$GATEWAY_TOKEN" > /root/.openclaw/.gateway-token
chmod 600 /root/.openclaw/.gateway-token

# ── systemd service ──────────────────────────────────────────
header "Installing systemd service"

cat > /etc/systemd/system/openclaw.service <<'EOF'
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment=HOME=/root
ExecStart=/usr/bin/openclaw gateway run
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Locate openclaw binary (may be in npm global bin)
OPENCLAW_PATH=$(which openclaw 2>/dev/null || npm bin -g 2>/dev/null)/openclaw
if [[ -x "$OPENCLAW_PATH" ]]; then
  sed -i "s|ExecStart=/usr/bin/openclaw|ExecStart=${OPENCLAW_PATH}|" \
    /etc/systemd/system/openclaw.service
fi

systemctl daemon-reload
systemctl enable openclaw
systemctl start openclaw
sleep 3

if systemctl is-active --quiet openclaw; then
  success "openclaw.service is running."
else
  warn "Service may still be starting. Check: journalctl -u openclaw -n 30"
fi

# ── Firewall ─────────────────────────────────────────────────
header "Configuring firewall (ufw)"

ufw --force reset >/dev/null
ufw default deny incoming  >/dev/null
ufw default allow outgoing >/dev/null
ufw allow ssh              >/dev/null
ufw allow 18789/tcp comment 'OpenClaw Gateway (LAN only)' >/dev/null
ufw --force enable         >/dev/null

success "Firewall enabled (SSH + port 18789 open)."

# ── Tailscale (optional) ─────────────────────────────────────
header "Installing Tailscale (optional but recommended)"

if ! command -v tailscale &>/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh 2>&1 | tail -3 || \
    warn "Tailscale install failed — install manually later."
fi

if command -v tailscale &>/dev/null; then
  success "Tailscale installed. Run 'tailscale up' to authenticate."
else
  warn "Tailscale not available. Use SSH tunnel for remote access."
fi

# ── Summary ──────────────────────────────────────────────────
CT_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}  OpenClaw setup complete!${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${BOLD}Dashboard:${NC}      http://${CT_IP}:18789"
echo -e "  ${BOLD}Gateway token:${NC}  ${GATEWAY_TOKEN}"
echo -e "  ${BOLD}Config file:${NC}    /root/.openclaw/openclaw.json"
echo -e "  ${BOLD}Service:${NC}        systemctl status openclaw"
echo -e "  ${BOLD}Logs:${NC}           journalctl -u openclaw -f"
echo ""
echo -e "  ${YELLOW}Next steps:${NC}"
echo "    1. openclaw onboard            — run the interactive setup wizard"
echo "    2. Add a channel (Telegram, Discord, Slack, etc.) in openclaw.json"
echo "    3. tailscale up                — (optional) secure remote access"
echo "    4. tailscale serve 18789       — expose dashboard via Tailscale HTTPS"
echo ""
echo -e "  ${YELLOW}Security:${NC}"
echo "    - The gateway token above authenticates the web dashboard."
echo "    - Do NOT expose port 18789 to the public internet."
echo "    - Use Tailscale Serve or an SSH tunnel for remote access."
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
