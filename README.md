# Proxmox on Hetzner Without Console Access

<div align="center">
  <img src="https://github.com/qoxi-cloud/proxmox-hetzner/raw/main/icons/proxmox.png" alt="Proxmox" height="64" />
  <img src="https://github.com/qoxi-cloud/proxmox-hetzner/raw/main/icons/hetzner.png" alt="Hetzner" height="50" />
  <h3>Automated Installation for Hetzner Dedicated Servers</h3>

  ![GitHub Stars](https://img.shields.io/github/stars/qoxi-cloud/proxmox-hetzner.svg)
  ![GitHub Watchers](https://img.shields.io/github/watchers/qoxi-cloud/proxmox-hetzner.svg)
  ![GitHub Forks](https://img.shields.io/github/forks/qoxi-cloud/proxmox-hetzner.svg)
</div>

## Overview

Automated Proxmox VE installation on Hetzner dedicated servers **without console access**. Works with [AX](https://www.hetzner.com/dedicated-rootserver/matrix-ax), [EX](https://www.hetzner.com/dedicated-rootserver/matrix-ex), and [SX](https://www.hetzner.com/dedicated-rootserver/matrix-sx) series.

**Key Features:**
- Interactive menus with arrow key navigation
- ZFS RAID selection (mirror, stripe, single)
- Network bridge modes (NAT, bridged, or both)
- SSH hardening & automatic security updates
- Optional Tailscale VPN integration

## Quick Start

### 1. Activate Rescue Mode

1. In [Hetzner Robot](https://robot.hetzner.com): go to **Rescue** tab
2. Select: Linux 64-bit, add your SSH key (optional)
3. Click **Activate rescue system**
4. Go to **Reset** tab → **Execute automatic hardware reset** → **Send**
5. Wait 2-3 minutes, then SSH into the server

### 2. Run Installation

```bash
bash <(curl -sSL https://github.com/qoxi-cloud/proxmox-hetzner/raw/main/pve-install.sh)
```

### 3. Access Proxmox

After reboot, open: `https://YOUR-SERVER-IP:8006`

Login: `root` / *your password*

## Documentation

| Document | Description |
|----------|-------------|
| [Configuration](docs/CONFIGURATION.md) | Command line options, environment variables |
| [Network Modes](docs/NETWORK.md) | NAT, bridged, and hybrid networking |
| [Post-Install](docs/POST-INSTALL.md) | Installed packages, security, optimizations |
| [Tailscale](docs/TAILSCALE.md) | Remote access setup |

## Automated Installation

For fully automated (non-interactive) installation:

```bash
export NEW_ROOT_PASSWORD="YourSecurePassword"
export SSH_PUBLIC_KEY="ssh-ed25519 AAAA... user@host"
bash <(curl -sSL https://github.com/qoxi-cloud/proxmox-hetzner/raw/main/pve-install.sh) -n
```

See [Configuration Guide](docs/CONFIGURATION.md) for all options.

---

<div align="center">
  <b>If this project saved you time, please consider giving it a star!</b><br><br>
  <a href="https://github.com/qoxi-cloud/proxmox-hetzner">
    <img src="https://img.shields.io/github/stars/qoxi-cloud/proxmox-hetzner?style=social" alt="Star on GitHub">
  </a>
</div>

## License

[MIT License](LICENSE)
