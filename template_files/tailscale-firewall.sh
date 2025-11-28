#!/bin/bash
# Tailscale-only access firewall rules
# Block all incoming connections to public IP, allow only Tailscale

IFACE="{{INTERFACE_NAME}}"

# Flush existing INPUT rules for the public interface
iptables -D INPUT -i "$IFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
iptables -D INPUT -i "$IFACE" -p icmp --icmp-type echo-request -j ACCEPT 2>/dev/null || true
iptables -D INPUT -i "$IFACE" -j DROP 2>/dev/null || true

# Allow established/related connections (for outbound traffic responses)
iptables -A INPUT -i "$IFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow ICMP ping for diagnostics
iptables -A INPUT -i "$IFACE" -p icmp --icmp-type echo-request -j ACCEPT

# Drop all other incoming connections on public interface
iptables -A INPUT -i "$IFACE" -j DROP

echo "Tailscale firewall rules applied: public IP access blocked"
