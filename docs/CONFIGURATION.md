# Configuration Guide

This document covers all configuration options for the Proxmox installation script.

## Command Line Options

| Option | Description |
|--------|-------------|
| `-h, --help` | Show help message |
| `-v, --version` | Show version |
| `-c, --config FILE` | Load configuration from file |
| `-s, --save-config FILE` | Save configuration to file after input |
| `-n, --non-interactive` | Run without prompts (requires `--config` or env vars) |

### Usage Examples

```bash
# Interactive installation (default)
bash pve-install.sh

# Save config for future use
bash pve-install.sh -s proxmox.conf

# Load config, prompt for missing values
bash pve-install.sh -c proxmox.conf

# Fully automated installation
bash pve-install.sh -c proxmox.conf -n
```

## Environment Variables

You can pre-configure any setting via environment variables. In **interactive mode**, pre-set variables will be skipped (shown with checkmark). In **non-interactive mode** (`-n`), they provide required values.

### Basic Settings

| Variable | Description | Default |
|----------|-------------|---------|
| `PVE_HOSTNAME` | Server hostname | `pve-qoxi-cloud` |
| `DOMAIN_SUFFIX` | Domain suffix for FQDN | `local` |
| `TIMEZONE` | System timezone | `Europe/Kyiv` |
| `EMAIL` | Admin email | `admin@qoxi.cloud` |
| `DEFAULT_SHELL` | Default shell: `zsh`, `bash` | `zsh` |

### Security (Required for non-interactive)

| Variable | Description | Default |
|----------|-------------|---------|
| `NEW_ROOT_PASSWORD` | Root password | - |
| `SSH_PUBLIC_KEY` | SSH public key | From rescue system |

### Network Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `INTERFACE_NAME` | Network interface | Auto-detected |
| `BRIDGE_MODE` | Network mode: `internal`, `external`, `both` | `internal` |
| `PRIVATE_SUBNET` | NAT subnet (CIDR) | `10.0.0.0/24` |

### Storage

| Variable | Description | Default |
|----------|-------------|---------|
| `ZFS_RAID` | ZFS mode: `single`, `raid0`, `raid1` | `raid1` (2+ disks) |

### Tailscale (Optional)

| Variable | Description | Default |
|----------|-------------|---------|
| `INSTALL_TAILSCALE` | Install Tailscale: `yes`, `no` | `no` |
| `TAILSCALE_AUTH_KEY` | Tailscale auth key | - |
| `TAILSCALE_SSH` | Enable Tailscale SSH | `yes` |
| `TAILSCALE_WEBUI` | Enable Tailscale Web UI | `yes` |

## Examples

### Semi-interactive (password from env)

```bash
export NEW_ROOT_PASSWORD="MySecurePass123"
bash pve-install.sh
```

### Multiple pre-configured values

```bash
export NEW_ROOT_PASSWORD="MySecurePass123"
export PVE_HOSTNAME="proxmox1"
export TIMEZONE="Europe/Berlin"
export INSTALL_TAILSCALE="yes"
export TAILSCALE_AUTH_KEY="tskey-auth-xxx"
bash pve-install.sh
```

### Fully automated (no config file)

```bash
export NEW_ROOT_PASSWORD="MySecurePass123"
export SSH_PUBLIC_KEY="ssh-ed25519 AAAA... user@host"
bash pve-install.sh -n
```

### Inline (single command)

```bash
NEW_ROOT_PASSWORD="pass" SSH_PUBLIC_KEY="ssh-ed25519 ..." bash pve-install.sh -n
```

> **Security Tip:** Use environment variables for sensitive data (passwords, auth keys) instead of storing them in config files.
