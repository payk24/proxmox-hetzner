# Tailscale Remote Access

Tailscale provides secure remote access to your Proxmox server from anywhere without exposing ports to the internet.

## Installation Options

### During Installation

Enable Tailscale by setting:

```bash
export INSTALL_TAILSCALE="yes"
export TAILSCALE_AUTH_KEY="tskey-auth-xxxxx"  # Optional but recommended
bash pve-install.sh
```

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `INSTALL_TAILSCALE` | Install Tailscale: `yes`, `no` | `no` |
| `TAILSCALE_AUTH_KEY` | Auth key for automatic setup | - |
| `TAILSCALE_SSH` | Enable Tailscale SSH | `yes` |
| `TAILSCALE_WEBUI` | Enable Tailscale Web UI proxy | `yes` |

## Access Methods

After installation, you can access your server via:

| Method | URL/Command |
|--------|-------------|
| **Web UI** | `https://YOUR-HOSTNAME.your-tailnet.ts.net` |
| **SSH** | `ssh root@YOUR-TAILSCALE-IP` |

## Setup Scenarios

### With Auth Key (Recommended)

If you provide `TAILSCALE_AUTH_KEY` during installation:
- Tailscale connects automatically after reboot
- SSH access via Tailscale is enabled
- Web UI is proxied through Tailscale HTTPS

No additional steps required.

### Without Auth Key

If you didn't provide an auth key, run these commands after the first reboot:

```bash
# Connect to Tailscale (opens browser for auth)
tailscale up --ssh

# Enable Web UI proxy
tailscale serve --bg --https=443 https://127.0.0.1:8006
```

## Getting an Auth Key

1. Go to [Tailscale Admin Console](https://login.tailscale.com/admin/settings/keys)
2. Click **Generate auth key**
3. Recommended settings:
   - Reusable: No (single use)
   - Expiration: 1 hour (or as needed)
   - Tags: Optional
4. Copy the key (starts with `tskey-auth-`)

## Security Notes

- Tailscale SSH bypasses the server's SSH daemon
- Access is controlled via Tailscale ACLs
- Web UI access requires Tailscale connection
- No ports need to be exposed to the public internet

## Troubleshooting

### Check Tailscale Status

```bash
tailscale status
```

### Restart Tailscale

```bash
systemctl restart tailscaled
```

### Re-authenticate

```bash
tailscale up --ssh --reset
```

### Check Web UI Proxy

```bash
tailscale serve status
```
