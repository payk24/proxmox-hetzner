# Network Configuration

This document explains the network bridge modes available during installation.

## Bridge Modes Overview

| Mode | Description | Configuration |
|------|-------------|---------------|
| **Internal only** | NAT network - VMs get private IPs | `vmbr0` = NAT bridge |
| **External only** | Bridged to physical NIC | `vmbr0` = bridged to NIC |
| **Both** | Internal + External networks | `vmbr0` = external, `vmbr1` = NAT |

## Internal Only (NAT)

Best for isolated VMs with internet access via NAT.

- VMs get private IPs (default: `10.0.0.0/24`)
- Host acts as NAT gateway
- No additional Hetzner IPs required
- Port forwarding needed for external access

```
Internet <-> Host (vmbr0 + NAT) <-> VMs (10.0.0.x)
```

## External Only (Bridged)

Best when you have additional public IPs from Hetzner.

- VMs get IPs directly from router/DHCP
- Direct network access (no NAT)
- Requires additional IP addresses from Hetzner
- VMs are directly exposed to internet

```
Internet <-> Host (vmbr0) <-> VMs (public IPs)
```

## Both (Recommended for Flexibility)

Combines both modes for maximum flexibility.

- `vmbr0` - External bridge (for VMs needing public IPs)
- `vmbr1` - Internal NAT bridge (for isolated VMs)
- Choose per-VM which network to use

```
Internet <-> Host <-> vmbr0 (external) <-> Public VMs
                  <-> vmbr1 (NAT)      <-> Private VMs (10.0.0.x)
```

## Choosing the Right Mode

| Use Case | Recommended Mode |
|----------|------------------|
| Simple homelab, no extra IPs | Internal only |
| Production with Hetzner IPs | External only |
| Mixed workloads | Both |
| Maximum security for VMs | Internal only |

## Custom Subnet

You can customize the NAT subnet via the `PRIVATE_SUBNET` environment variable:

```bash
export PRIVATE_SUBNET="192.168.100.0/24"
bash pve-install.sh
```
