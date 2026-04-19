# OpenClaw — Proxmox LXC Installer

Community-scripts-style one-liner installer for [OpenClaw](https://openclaw.ai) 

## What you get

- Unprivileged **Debian 13 LXC** container
- **Node.js 24** + OpenClaw (latest)
- **systemd service** (`openclaw.service`) that auto-starts on boot
- **Gateway token** auth pre-configured
- **ufw firewall** rules (SSH + port 18789 open, everything else blocked)
- **Tailscale** installed and ready to authenticate
- WebChat enabled out of the box

## Requirements

| Component | Minimum |
|-----------|---------|
| Proxmox VE | 7.x or 8.x |
| RAM | 2 GB (1 GB if no browser automation) |
| Disk | 8 GB |
| CPU | 2 cores |
| Internet | Required for template download + npm |

You'll also need an **AI provider API key** (Anthropic, OpenAI, Groq, etc.) — OpenClaw won't do much without one.

---

## Quick Install

Run this from the **Proxmox host shell** (not inside a container):

```bash
bash -c "$(curl -fsSL - https://raw.githubusercontent.com/kellandamm/openclaw-lab/main/scripts/install.sh)"
```

The script will prompt you for:
- Container ID, hostname, IP, storage pool, RAM, CPU, disk size
- A root password for the container

Everything else is automatic (~3–5 minutes).

---

## Manual / Standalone (already have an LXC?)

If you already have a Debian 12/13 container, run the inner setup script directly inside it:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kellandamm/openclaw-lab/main/scripts/setup-inside-ct.sh)
```

---

## Post-Install

### 1. Shell into the container
```bash
pct enter <VMID>
```

### 2. Run the OpenClaw onboarding wizard
```bash
openclaw onboard
```
This walks you through connecting an AI provider, setting up channels (Telegram, Discord, Slack, WhatsApp, etc.), and configuring your workspace.

### 3. Add channels manually (optional)
Edit `/root/.openclaw/openclaw.json`:

```jsonc
{
  "agent": {
    "model": "anthropic/claude-opus-4-6"
  },
  "channels": {
    "telegram": {
      "enabled": true,
      "botToken": "YOUR_TELEGRAM_BOT_TOKEN",
      "dmPolicy": "pairing"
    },
    "discord": {
      "enabled": true,
      "token": "YOUR_DISCORD_BOT_TOKEN"
    }
  }
}
```

Then restart the service:
```bash
systemctl restart openclaw
```

### 4. Set up Tailscale (recommended for remote access)
```bash
tailscale up
# Authenticate via the printed URL

tailscale serve 18789
# Your dashboard is now available at https://openclaw.<tailnet>.ts.net
```

> **Never expose port 18789 directly to the internet.** Use Tailscale or an SSH tunnel.

---

## Useful Commands

```bash
# Service management
systemctl status openclaw
systemctl restart openclaw
journalctl -u openclaw -f          # live logs

# OpenClaw CLI
openclaw models status             # check AI provider auth
openclaw models set groq/openai/gpt-oss-120b
openclaw pairing list              # see pending pairing requests
openclaw pairing approve telegram <code>
openclaw update                    # update to latest

# Update via npm
npm update -g openclaw
systemctl restart openclaw
```

---

## Resource Usage

| Scenario | RAM |
|----------|-----|
| Idle (no browser) | ~400 MB |
| Active agent + browser | ~1.5–2 GB |
| With local Ollama model | 8 GB+ |

---

## Security Notes

- The gateway runs on port **18789** — only accessible on your LAN by default
- The dashboard requires a **bearer token** (generated during install, stored in `openclaw.json`)
- ufw blocks all inbound except SSH and 18789
- The container runs **unprivileged** (container root ≠ host root)
- For Telegram/Discord, set `dmPolicy: "pairing"` to prevent strangers from using your agent
- Review [OpenClaw's security guide](https://docs.openclaw.ai/gateway/security) before exposing to the internet

---

## Files

| File | Purpose |
|------|---------|
| `install.sh` | Runs on the **Proxmox host** — creates the LXC and calls the inner script |
| `setup-inside-ct.sh` | Runs **inside the container** — installs everything |

---

## Troubleshooting

**Service won't start**
```bash
journalctl -u openclaw -n 50 --no-pager
openclaw doctor
```

**Can't reach the dashboard**
- Check the container has an IP: `pct exec <VMID> -- hostname -I`
- Check ufw isn't blocking: `pct exec <VMID> -- ufw status`
- Check the service is running: `pct exec <VMID> -- systemctl status openclaw`

**Tailscale TUN error**
Make sure the LXC config has TUN/TAP enabled. The install script does this automatically; if you're using an existing container, add to `/etc/pve/lxc/<VMID>.conf`:
```
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```
Then restart the container.
