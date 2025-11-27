#!/bin/bash
# Proxmox VE Firewall Setup Script
# This script configures iptables rules for a Proxmox server

export DEBIAN_FRONTEND=noninteractive
apt-get install -yqq iptables-persistent netfilter-persistent

# =============================================================================
# IPv4 Rules
# =============================================================================

# Flush existing rules
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X

# Default policies
iptables -P INPUT DROP
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT

# Allow established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow ICMP (ping)
iptables -A INPUT -p icmp -j ACCEPT

# Allow SSH (port 22)
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# Allow Proxmox Web UI (port 8006)
iptables -A INPUT -p tcp --dport 8006 -j ACCEPT

# Allow VNC console (ports 5900-5999)
iptables -A INPUT -p tcp --dport 5900:5999 -j ACCEPT

# Allow Spice console (port 3128)
iptables -A INPUT -p tcp --dport 3128 -j ACCEPT

# Allow Proxmox cluster communication (if needed)
iptables -A INPUT -p tcp --dport 111 -j ACCEPT
iptables -A INPUT -p udp --dport 111 -j ACCEPT
iptables -A INPUT -p tcp --dport 85 -j ACCEPT

# Allow internal bridge traffic
iptables -A INPUT -i vmbr+ -j ACCEPT

# Save IPv4 rules
netfilter-persistent save

# =============================================================================
# IPv6 Rules
# =============================================================================

ip6tables -F
ip6tables -P INPUT DROP
ip6tables -P FORWARD ACCEPT
ip6tables -P OUTPUT ACCEPT
ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
ip6tables -A INPUT -p ipv6-icmp -j ACCEPT
ip6tables -A INPUT -p tcp --dport 22 -j ACCEPT
ip6tables -A INPUT -p tcp --dport 8006 -j ACCEPT
ip6tables -A INPUT -p tcp --dport 5900:5999 -j ACCEPT
ip6tables -A INPUT -p tcp --dport 3128 -j ACCEPT
ip6tables -A INPUT -i vmbr+ -j ACCEPT

# Save IPv6 rules
netfilter-persistent save
