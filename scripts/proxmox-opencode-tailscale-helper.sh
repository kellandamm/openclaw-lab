#!/usr/bin/env bash
set -Eeuo pipefail

YW='\033[33m'
GN='\033[1;92m'
RD='\033[01;31m'
BL='\033[36m'
CL='\033[m'
BOLD='\033[1m'

trap 'error_handler $LINENO "$BASH_COMMAND"' ERR

error_handler() {
  local line="$1"
  local cmd="$2"
  clear || true
  echo -e "${RD}${BOLD}Error${CL}: command failed on line ${line}"
  echo -e "${YW}${cmd}${CL}"
  exit 1
}

msg() { echo -e "${BL}${BOLD}==>${CL} $*"; }
ok() { echo -e "${GN}${BOLD}✓${CL} $*"; }
warn() { echo -e "${YW}${BOLD}!${CL} $*"; }
fail() { echo -e "${RD}${BOLD}✗${CL} $*"; exit 1; }

APP="OpenCode Tailscale Dev Box"
TEMPLATE_DEFAULT="ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
HOSTNAME_DEFAULT="opencode-box"
CTID_DEFAULT="220"
CORES_DEFAULT="4"
MEMORY_DEFAULT="4096"
SWAP_DEFAULT="512"
DISK_DEFAULT="16"
USERNAME_DEFAULT="coder"
BRIDGE_DEFAULT="vmbr0"
IP_DEFAULT="dhcp"
TAGS_DEFAULT="tag:server"

require_root() {
  [[ $(id -u) -eq 0 ]] || fail "Run as root on a Proxmox VE host."
}

require_cmds() {
  local missing=()
  for cmd in whiptail pct pveam pvesm awk sed grep cut tr sort head systemctl; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  (( ${#missing[@]} == 0 )) || fail "Missing commands: ${missing[*]}"
}

backtitle() {
  echo "Proxmox VE Helper Scripts | ${APP}"
}

info_box() {
  whiptail --backtitle "$(backtitle)" --title "$1" --msgbox "$2" 12 74
}

yesno() {
  whiptail --backtitle "$(backtitle)" --title "$1" --yesno "$2" 12 74
}

input_box() {
  local title="$1" prompt="$2" value="$3"
  whiptail --backtitle "$(backtitle)" --title "$title" --inputbox "$prompt" 12 74 "$value" 3>&1 1>&2 2>&3
}

password_box() {
  local title="$1" prompt="$2"
  whiptail --backtitle "$(backtitle)" --title "$title" --passwordbox "$prompt" 12 74 3>&1 1>&2 2>&3
}

menu_box() {
  local title="$1" prompt="$2"
  shift 2
  whiptail --backtitle "$(backtitle)" --title "$title" --menu "$prompt" 18 84 8 "$@" 3>&1 1>&2 2>&3
}

pick_storage() {
  pvesm status --content rootdir 2>/dev/null | awk 'NR>1 {print $1}' | sort | head -n1
}

pick_template_storage() {
  pvesm status --content vztmpl 2>/dev/null | awk 'NR>1 {print $1}' | sort | head -n1
}

ensure_template() {
  local tpl_storage="$1"
  local template="$2"
  msg "Refreshing container template list"
  pveam update >/dev/null
  pveam available | grep -q "$template" || fail "Template $template not found in available templates."
  if ! pveam list "$tpl_storage" 2>/dev/null | grep -q "$template"; then
    msg "Downloading template $template to $tpl_storage"
    pveam download "$tpl_storage" "$template" >/dev/null
  fi
  ok "Template ready: $template"
}

pct_exec() {
  local ctid="$1"
  shift
  pct exec "$ctid" -- bash -lc "$*"
}

generate_password() {
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20
}

collect_config() {
  STORAGE_DEFAULT=$(pick_storage)
  TEMPLATE_STORAGE_DEFAULT=$(pick_template_storage)
  [[ -n "$STORAGE_DEFAULT" ]] || fail "No rootdir-capable storage found."
  [[ -n "$TEMPLATE_STORAGE_DEFAULT" ]] || fail "No template-capable storage found."

  CTID=$(input_box "Container ID" "Numeric ID for the new LXC." "$CTID_DEFAULT") || exit 1
  [[ "$CTID" =~ ^[0-9]+$ ]] || fail "CTID must be numeric."
  pct status "$CTID" >/dev/null 2>&1 && fail "CTID $CTID already exists."

  HOSTNAME=$(input_box "Hostname" "Container hostname." "$HOSTNAME_DEFAULT") || exit 1
  STORAGE=$(input_box "RootFS Storage" "Storage for the container disk." "$STORAGE_DEFAULT") || exit 1
  TEMPLATE_STORAGE=$(input_box "Template Storage" "Storage that holds LXC templates." "$TEMPLATE_STORAGE_DEFAULT") || exit 1
  TEMPLATE=$(input_box "Template" "Ubuntu LXC template name." "$TEMPLATE_DEFAULT") || exit 1
  DISK=$(input_box "Disk Size" "Disk size in GB." "$DISK_DEFAULT") || exit 1
  CORES=$(input_box "CPU Cores" "vCPU core count." "$CORES_DEFAULT") || exit 1
  MEMORY=$(input_box "Memory" "Memory in MB." "$MEMORY_DEFAULT") || exit 1
  SWAP=$(input_box "Swap" "Swap in MB." "$SWAP_DEFAULT") || exit 1
  BRIDGE=$(input_box "Bridge" "Network bridge name." "$BRIDGE_DEFAULT") || exit 1
  IP4=$(input_box "IPv4" "Use dhcp or a CIDR like 192.168.1.50/24." "$IP_DEFAULT") || exit 1
  GW=""
  if [[ "$IP4" != "dhcp" ]]; then
    GW=$(input_box "Gateway" "Gateway IPv4 for static address." "") || exit 1
  fi
  USERNAME=$(input_box "Username" "Primary SSH user to create." "$USERNAME_DEFAULT") || exit 1
  PASSWORD_DEFAULT=$(generate_password)
  PASSWORD=$(password_box "Password" "Password for ${USERNAME}. Leave blank to use generated value shown in summary.") || true
  PASSWORD=${PASSWORD:-$PASSWORD_DEFAULT}

  if yesno "Tailscale Mode" "Enable /dev/net/tun and run Tailscale in normal mode? Choose No to use userspace networking."; then
    TS_MODE="tun"
  else
    TS_MODE="userspace"
  fi

  if yesno "Auto Authenticate" "Use a Tailscale auth key during install? Choose No for interactive tailscale up later."; then
    TS_AUTHKEY=$(password_box "Tailscale Auth Key" "Paste a Tailscale auth key (tskey-...).") || exit 1
    AUTH_METHOD="key"
    if yesno "Advertise Tags" "Pass advertise-tags during tailscale up? Use this only if your auth key and policy allow it."; then
      TS_TAGS=$(input_box "Advertise Tags" "Comma-separated tags." "$TAGS_DEFAULT") || exit 1
    else
      TS_TAGS=""
    fi
  else
    TS_AUTHKEY=""
    TS_TAGS=""
    AUTH_METHOD="interactive"
  fi

  SUMMARY="CTID: $CTID
Hostname: $HOSTNAME
Storage: $STORAGE
Template storage: $TEMPLATE_STORAGE
Template: $TEMPLATE
Disk: ${DISK}G
CPU: $CORES
Memory: ${MEMORY} MB
Swap: ${SWAP} MB
Bridge: $BRIDGE
IPv4: $IP4
Gateway: ${GW:-none}
User: $USERNAME
Tailscale mode: $TS_MODE
Tailscale auth: $AUTH_METHOD"

  yesno "Confirm" "$SUMMARY" || exit 1
}

create_container() {
  ensure_template "$TEMPLATE_STORAGE" "$TEMPLATE"

  local netcfg="name=eth0,bridge=${BRIDGE},ip=${IP4}"
  [[ -n "$GW" ]] && netcfg+=",gw=${GW}"

  msg "Creating LXC $CTID"
  pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "$HOSTNAME" \
    --ostype ubuntu \
    --unprivileged 1 \
    --features nesting=1,keyctl=1 \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --swap "$SWAP" \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "$netcfg" \
    --onboot 1 \
    --start 0 >/dev/null

  if [[ "$TS_MODE" == "tun" ]]; then
    msg "Passing /dev/net/tun into the container"
    pct set "$CTID" --dev0 /dev/net/tun >/dev/null
  fi

  ok "Container created"
}

configure_container() {
  msg "Starting container"
  pct start "$CTID"
  sleep 10

  msg "Installing base packages"
  pct_exec "$CTID" "export DEBIAN_FRONTEND=noninteractive && apt-get update && apt-get install -y curl wget git tmux sudo openssh-server ca-certificates gnupg lsb-release jq unzip bash-completion software-properties-common vim"

  msg "Installing Node.js 22"
  pct_exec "$CTID" "curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt-get install -y nodejs"

  msg "Installing Tailscale"
  pct_exec "$CTID" "curl -fsSL https://tailscale.com/install.sh | sh"

  msg "Installing OpenCode"
  pct_exec "$CTID" "curl -fsSL https://opencode.ai/install | bash"

  msg "Creating user and workspace"
  pct_exec "$CTID" "id -u '$USERNAME' >/dev/null 2>&1 || useradd -m -s /bin/bash '$USERNAME'; echo '$USERNAME:$PASSWORD' | chpasswd; usermod -aG sudo '$USERNAME'; mkdir -p /home/$USERNAME/.ssh /workspace /etc/opencode; chown -R $USERNAME:$USERNAME /home/$USERNAME /workspace; printf '%s\n' 'PasswordAuthentication yes' 'PermitRootLogin no' > /etc/ssh/sshd_config.d/99-opencode.conf; systemctl enable ssh >/dev/null 2>&1 || systemctl enable sshd >/dev/null 2>&1; systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1"

  msg "Writing environment profile"
  pct_exec "$CTID" "cat >/etc/profile.d/opencode-env.sh <<EOF2
export PATH=\"/root/.local/bin:/home/$USERNAME/.local/bin:\$PATH\"
export EDITOR=vim
export VISUAL=vim
export TERM=xterm-256color
EOF2
chmod 644 /etc/profile.d/opencode-env.sh"

  msg "Creating first-run notes"
  pct_exec "$CTID" "cat >/etc/motd <<EOF2
${APP}

- Login user: $USERNAME
- Workspace: /workspace
- Start a durable session: tmux
- Start OpenCode: opencode /workspace
EOF2"

  if [[ "$TS_MODE" == "tun" ]]; then
    msg "Enabling normal tailscaled service"
    pct_exec "$CTID" "systemctl enable tailscaled && systemctl restart tailscaled"
    if [[ -n "$TS_AUTHKEY" ]]; then
      local upcmd="tailscale up --ssh --accept-routes=false --hostname '$HOSTNAME' --auth-key '$TS_AUTHKEY'"
      [[ -n "$TS_TAGS" ]] && upcmd+=" --advertise-tags '$TS_TAGS'"
      msg "Authenticating Tailscale with auth key"
      pct_exec "$CTID" "$upcmd"
      TS_NEXT="Tailscale already authenticated."
    else
      TS_NEXT="Run inside container: tailscale up --ssh --hostname $HOSTNAME"
    fi
  else
    msg "Configuring userspace tailscaled service"
    pct_exec "$CTID" "cat >/etc/systemd/system/tailscaled-userspace.service <<'EOF2'
[Unit]
Description=Tailscale userspace daemon
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/sbin/tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/run/tailscale/tailscaled.sock --tun=userspace-networking --socks5-server=localhost:1055 --outbound-http-proxy-listen=localhost:1055
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF2
systemctl disable --now tailscaled >/dev/null 2>&1 || true
systemctl daemon-reload
systemctl enable --now tailscaled-userspace.service"
    if [[ -n "$TS_AUTHKEY" ]]; then
      local upcmd="tailscale --socket /run/tailscale/tailscaled.sock up --ssh --accept-routes=false --hostname '$HOSTNAME' --auth-key '$TS_AUTHKEY'"
      [[ -n "$TS_TAGS" ]] && upcmd+=" --advertise-tags '$TS_TAGS'"
      msg "Authenticating Tailscale userspace mode with auth key"
      pct_exec "$CTID" "$upcmd"
      pct_exec "$CTID" "cat >/etc/profile.d/tailscale-proxy.sh <<'EOF2'
export ALL_PROXY=socks5://127.0.0.1:1055
export HTTP_PROXY=http://127.0.0.1:1055
export HTTPS_PROXY=http://127.0.0.1:1055
EOF2
chmod 644 /etc/profile.d/tailscale-proxy.sh"
      TS_NEXT="Tailscale userspace mode authenticated; outbound tools can use the local proxy env vars."
    else
      TS_NEXT="Run inside container: tailscale --socket /run/tailscale/tailscaled.sock up --ssh --hostname $HOSTNAME"
    fi
  fi

  ok "Container configured"
}

show_result() {
  local ctip
  ctip=$(pct exec "$CTID" -- bash -lc "hostname -I | awk '{print \$1}'" 2>/dev/null || true)
  local result
  result="Deployment complete.

CTID: $CTID
Hostname: $HOSTNAME
IP: ${ctip:-unknown}
User: $USERNAME
Password: $PASSWORD
Workspace: /workspace

Next:
1. pct enter $CTID
2. su - $USERNAME
3. cd /workspace
4. tmux
5. opencode

Tailscale:
$TS_NEXT

Phone:
Use Termius to SSH to the Tailscale IP or MagicDNS hostname."
  whiptail --backtitle "$(backtitle)" --title "Completed" --msgbox "$result" 22 78
}

main() {
  require_root
  require_cmds
  info_box "$APP" "This Proxmox VE Helper-style script builds an Ubuntu LXC with OpenCode, SSH, tmux, Node.js, and Tailscale. It supports either /dev/net/tun or Tailscale userspace mode."
  collect_config
  create_container
  configure_container
  show_result
  clear
  ok "Finished"
}

main "$@"
