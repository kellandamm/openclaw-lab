#!/usr/bin/env bash
# ============================================================
# OpenClaw LXC Installer for Proxmox VE
# Community-scripts style — run from the Proxmox host shell
#
# Usage:
#   bash -c "$(curl -fsSL - https://raw.githubusercontent.com/YOUR_REPO/openclaw-proxmox/main/scriptsinstall.sh)"
#
# What this does:
#   1. Prompts for config (VMID, hostname, IP, storage, resources)
#   2. Downloads a Debian 13 template if needed
#   3. Creates an unprivileged LXC container
#   4. Runs the inner setup script inside the container
#   5. Prints connection URLs and the gateway token when done
# ============================================================

set -euo pipefail

# ── Colors ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}=== $* ===${NC}\n"; }

# ── Preflight ────────────────────────────────────────────────
[[ $(id -u) -eq 0 ]] || error "Run this script as root on the Proxmox host."
command -v pct  &>/dev/null || error "pct not found — is this a Proxmox VE host?"
command -v pvesh &>/dev/null || error "pvesh not found — is this a Proxmox VE host?"

header "OpenClaw LXC Installer"
echo "  Installs OpenClaw (personal AI agent) into an unprivileged"
echo "  Debian 13 LXC container with systemd service + Tailscale."
echo ""

# ── Interactive Config ───────────────────────────────────────
NEXT_ID=$(pvesh get /cluster/nextid 2>/dev/null || echo 200)

read -rp "  Container ID      [${NEXT_ID}]: "      VMID;      VMID=${VMID:-$NEXT_ID}
read -rp "  Hostname          [openclaw]: "         HOSTNAME;  HOSTNAME=${HOSTNAME:-openclaw}
read -rp "  CPU cores         [2]: "                CORES;     CORES=${CORES:-2}
read -rp "  RAM (MB)          [2048]: "             MEMORY;    MEMORY=${MEMORY:-2048}
read -rp "  Disk size (GB)    [8]: "                DISK;      DISK=${DISK:-8}
read -rp "  Storage pool      [local-lvm]: "        STORAGE;   STORAGE=${STORAGE:-local-lvm}
read -rp "  Network bridge    [vmbr0]: "            BRIDGE;    BRIDGE=${BRIDGE:-vmbr0}
read -rp "  IP (CIDR or dhcp) [dhcp]: "             IP;        IP=${IP:-dhcp}
if [[ "$IP" != "dhcp" ]]; then
  read -rp "  Gateway IP                : "         GW
fi
read -rp "  DNS server        [8.8.8.8]: "          DNS;       DNS=${DNS:-8.8.8.8}
read -rsp "  Root password              : "         CT_PASS;   echo ""
[[ -n "$CT_PASS" ]] || error "Password cannot be empty."

echo ""
echo "  Alert channel (optional — for watchdog notifications):"
read -rp "  Make.com webhook URL  [skip]: "  ALERT_WEBHOOK; ALERT_WEBHOOK=${ALERT_WEBHOOK:-}
if [[ -z "$ALERT_WEBHOOK" ]]; then
  read -rp "  Telegram bot token    [skip]: "  ALERT_TG_TOKEN; ALERT_TG_TOKEN=${ALERT_TG_TOKEN:-}
  if [[ -n "$ALERT_TG_TOKEN" ]]; then
    read -rp "  Telegram chat ID             : "  ALERT_TG_CHAT
  fi
fi

echo ""

# ── Template ─────────────────────────────────────────────────
header "Checking Debian 13 template"

TEMPLATE_STORAGE="local"
TEMPLATE_NAME="debian-13-standard_13.1-2_amd64.tar.zst"
TEMPLATE_PATH="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}"

if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TEMPLATE_NAME"; then
  info "Downloading Debian 13 template..."
  pveam update &>/dev/null || true
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME" \
    || error "Template download failed. Check internet access from this host."
  success "Template downloaded."
else
  success "Template already present."
fi

# ── Create Container ─────────────────────────────────────────
header "Creating LXC container (ID: ${VMID})"

NET_OPTS="name=eth0,bridge=${BRIDGE}"
if [[ "$IP" == "dhcp" ]]; then
  NET_OPTS+=",ip=dhcp"
else
  NET_OPTS+=",ip=${IP},gw=${GW}"
fi

pct create "$VMID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}" \
  --hostname    "$HOSTNAME"    \
  --password    "$CT_PASS"     \
  --cores       "$CORES"       \
  --memory      "$MEMORY"      \
  --swap        512            \
  --rootfs      "${STORAGE}:${DISK}" \
  --net0        "$NET_OPTS"    \
  --nameserver  "$DNS"         \
  --features    keyctl=1,nesting=0 \
  --unprivileged 1             \
  --onboot      1              \
  --start       0

# Enable TUN for Tailscale (required)
cat >> /etc/pve/lxc/${VMID}.conf <<EOF
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF

success "Container created."

# ── Start Container ──────────────────────────────────────────
info "Starting container..."
pct start "$VMID"
sleep 5  # give systemd a moment

# ── Inject Setup Script ──────────────────────────────────────
header "Installing OpenClaw inside container"

SETUP_SCRIPT_URL="https://raw.githubusercontent.com/kellandamm/openclaw-lab/main/scripts/setup-inside-ct.sh)"

# If running locally, push the sibling script directly
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INNER_SCRIPT="${SCRIPT_DIR}/setup-inside-ct.sh"

if [[ -f "$INNER_SCRIPT" ]]; then
  info "Copying setup script into container..."
  pct push "$VMID" "$INNER_SCRIPT" /root/setup-inside-ct.sh --perms 0700
else
  info "Downloading setup script..."
  pct exec "$VMID" -- bash -c \
    "curl -fsSL '${SETUP_SCRIPT_URL}' -o /root/setup-inside-ct.sh && chmod +x /root/setup-inside-ct.sh"
fi

info "Running setup (this takes ~3–5 minutes)..."

INNER_ARGS=""
[[ -n "${ALERT_WEBHOOK:-}" ]]   && INNER_ARGS="--alert-webhook '${ALERT_WEBHOOK}'"
[[ -n "${ALERT_TG_TOKEN:-}" ]]  && INNER_ARGS="--alert-telegram '${ALERT_TG_TOKEN}' '${ALERT_TG_CHAT}'"

pct exec "$VMID" -- bash -c "/root/setup-inside-ct.sh ${INNER_ARGS}"

# ── Done ─────────────────────────────────────────────────────
header "Installation Complete"

CT_IP=$(pct exec "$VMID" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "<container-ip>")
GATEWAY_TOKEN=$(pct exec "$VMID" -- bash -c \
  "grep -oP '(?<=\"token\":\")[^\"]+' /root/.openclaw/openclaw.json 2>/dev/null | head -1" \
  || echo "<run: openclaw gateway token on the container>")

echo -e "${BOLD}Container ID:${NC}    ${VMID}"
echo -e "${BOLD}Hostname:${NC}        ${HOSTNAME}"
echo -e "${BOLD}IP Address:${NC}      ${CT_IP}"
echo ""
echo -e "${BOLD}Dashboard:${NC}       http://${CT_IP}:18789"
echo -e "${BOLD}Gateway token:${NC}   ${GATEWAY_TOKEN}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Shell into the container:  pct enter ${VMID}"
echo "  2. Run the setup wizard:      openclaw onboard"
echo "  3. Connect a channel:         Telegram, Discord, Slack, WhatsApp, etc."
echo "  4. (Optional) Set up Tailscale for secure remote access:"
echo "       tailscale up"
echo "       tailscale serve 18789"
echo ""
echo -e "${YELLOW}Security reminders:${NC}"
echo "  - Do NOT expose port 18789 to the public internet."
echo "  - Use Tailscale Serve or an SSH tunnel for remote access."
echo "  - Set channel allowlists in ~/.openclaw/openclaw.json"
echo ""
success "OpenClaw is running. Run: pct enter ${VMID} to begin."
