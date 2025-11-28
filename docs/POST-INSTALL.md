# Post-Installation Details

The installation script automatically applies the following optimizations after Proxmox is installed.

## Installed Packages

| Package | Purpose |
|---------|---------|
| `zsh` | Modern shell with plugins (optional, selected by default) |
| `btop` | Modern system monitor (CPU, RAM, disk, network) |
| `iotop` | Disk I/O monitoring |
| `ncdu` | Interactive disk usage analyzer |
| `tmux` | Terminal multiplexer (persistent sessions) |
| `pigz` | Parallel gzip (faster backup compression) |
| `smartmontools` | Disk health monitoring (SMART) |
| `jq` | JSON parser (useful for API/scripts) |
| `bat` | Modern `cat` with syntax highlighting |
| `libguestfs-tools` | VM image manipulation tools |
| `chrony` | NTP time synchronization |
| `unattended-upgrades` | Automatic security updates |

## Security Hardening

| Feature | Configuration |
|---------|---------------|
| SSH authentication | Key-only (password disabled) |
| SSH ciphers | Modern only (ChaCha20, AES-GCM) |
| SSH limits | Max 3 auth attempts, 30s grace time |
| Root login | Allowed with key only (`prohibit-password`) |
| Security updates | Automatic via unattended-upgrades |
| Kernel updates | Excluded from auto-updates (manual reboot required) |

## System Optimizations

| Optimization | Details |
|--------------|---------|
| Package updates | All packages updated (`apt dist-upgrade`) |
| ZFS ARC limits | Dynamically calculated based on system RAM |
| nf_conntrack | Optimized for 1M+ connections |
| CPU governor | Set to `performance` mode |
| NTP sync | Chrony with Hetzner NTP servers |
| UTF-8 locales | Properly configured for all apps |
| Subscription notice | Removed from web UI |
| Enterprise repos | Disabled (no subscription required) |

## ZFS Configuration

The script automatically configures ZFS based on your selection:

| Mode | Description | Use Case |
|------|-------------|----------|
| `raid1` | Mirror (default) | Redundancy, data safety |
| `raid0` | Stripe | Maximum performance, no redundancy |
| `single` | Single disk | One disk or manual setup |

ZFS ARC (cache) memory limits are calculated dynamically:
- Small systems (< 32GB): 50% of RAM
- Medium systems (32-64GB): 60% of RAM
- Large systems (> 64GB): 70% of RAM
