#!/bin/bash
# ============================================
# Cloudflare IP Whitelist Updater for SSH
# Updates iptables rules to only allow SSH from Cloudflare
# Run via cron: 0 */6 * * * /usr/local/bin/update-cloudflare-ips.sh
# ============================================

set -e

# Configuration
CLOUDFLARE_IPV4_URL="https://www.cloudflare.com/ips-v4"
CLOUDFLARE_IPV6_URL="https://www.cloudflare.com/ips-v6"
IPSET_NAME_V4="cloudflare-ipv4"
IPSET_NAME_V6="cloudflare-ipv6"
LOG_FILE="/var/log/cloudflare-ip-update.log"
SSH_PORT="${SSH_PORT:-22}"

# Colors for output
CLR_GREEN="\033[1;32m"
CLR_YELLOW="\033[1;33m"
CLR_RED="\033[1;31m"
CLR_RESET="\033[m"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

error_exit() {
    echo -e "${CLR_RED}ERROR: $1${CLR_RESET}" | tee -a "$LOG_FILE"
    exit 1
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    error_exit "This script must be run as root"
fi

# Ensure ipset is installed
if ! command -v ipset &> /dev/null; then
    log "Installing ipset..."
    apt-get update -qq && apt-get install -yqq ipset
fi

# Fetch Cloudflare IPs
log "Fetching Cloudflare IPv4 ranges..."
CF_IPV4=$(curl -sf "$CLOUDFLARE_IPV4_URL") || error_exit "Failed to fetch Cloudflare IPv4 ranges"

log "Fetching Cloudflare IPv6 ranges..."
CF_IPV6=$(curl -sf "$CLOUDFLARE_IPV6_URL") || error_exit "Failed to fetch Cloudflare IPv6 ranges"

# Validate we got data
if [[ -z "$CF_IPV4" ]]; then
    error_exit "Cloudflare IPv4 list is empty"
fi

# Count IPs for logging
IPV4_COUNT=$(echo "$CF_IPV4" | wc -l)
IPV6_COUNT=$(echo "$CF_IPV6" | wc -l)
log "Retrieved $IPV4_COUNT IPv4 ranges and $IPV6_COUNT IPv6 ranges"

# Create temporary ipsets
TEMP_V4="${IPSET_NAME_V4}-temp"
TEMP_V6="${IPSET_NAME_V6}-temp"

# Clean up any existing temp sets
ipset destroy "$TEMP_V4" 2>/dev/null || true
ipset destroy "$TEMP_V6" 2>/dev/null || true

# Create new IPv4 ipset
log "Creating IPv4 ipset..."
ipset create "$TEMP_V4" hash:net family inet hashsize 1024 maxelem 65536

for ip in $CF_IPV4; do
    ipset add "$TEMP_V4" "$ip" 2>/dev/null || log "Warning: Could not add $ip to ipset"
done

# Create new IPv6 ipset
log "Creating IPv6 ipset..."
ipset create "$TEMP_V6" hash:net family inet6 hashsize 1024 maxelem 65536

for ip in $CF_IPV6; do
    ipset add "$TEMP_V6" "$ip" 2>/dev/null || log "Warning: Could not add $ip to ipset"
done

# Swap ipsets atomically
log "Swapping ipsets..."

# Create main sets if they don't exist
if ! ipset list "$IPSET_NAME_V4" &>/dev/null; then
    ipset create "$IPSET_NAME_V4" hash:net family inet hashsize 1024 maxelem 65536
fi
if ! ipset list "$IPSET_NAME_V6" &>/dev/null; then
    ipset create "$IPSET_NAME_V6" hash:net family inet6 hashsize 1024 maxelem 65536
fi

# Swap (atomic operation)
ipset swap "$TEMP_V4" "$IPSET_NAME_V4"
ipset swap "$TEMP_V6" "$IPSET_NAME_V6"

# Destroy temp sets
ipset destroy "$TEMP_V4"
ipset destroy "$TEMP_V6"

# Save ipsets for persistence across reboots
log "Saving ipsets..."
ipset save > /etc/ipset.conf

# Setup iptables rules if not already present
log "Checking iptables rules..."

# Check if our SSH rules exist
if ! iptables -C INPUT -p tcp --dport "$SSH_PORT" -m set --match-set "$IPSET_NAME_V4" src -j ACCEPT 2>/dev/null; then
    log "Adding IPv4 SSH accept rule..."
    # Insert at position 1 (before any drop rules)
    iptables -I INPUT 1 -p tcp --dport "$SSH_PORT" -m set --match-set "$IPSET_NAME_V4" src -j ACCEPT
fi

if ! iptables -C INPUT -p tcp --dport "$SSH_PORT" -m set ! --match-set "$IPSET_NAME_V4" src -j DROP 2>/dev/null; then
    log "Adding IPv4 SSH drop rule..."
    iptables -A INPUT -p tcp --dport "$SSH_PORT" -m set ! --match-set "$IPSET_NAME_V4" src -j DROP
fi

# IPv6 rules
if ! ip6tables -C INPUT -p tcp --dport "$SSH_PORT" -m set --match-set "$IPSET_NAME_V6" src -j ACCEPT 2>/dev/null; then
    log "Adding IPv6 SSH accept rule..."
    ip6tables -I INPUT 1 -p tcp --dport "$SSH_PORT" -m set --match-set "$IPSET_NAME_V6" src -j ACCEPT
fi

if ! ip6tables -C INPUT -p tcp --dport "$SSH_PORT" -m set ! --match-set "$IPSET_NAME_V6" src -j DROP 2>/dev/null; then
    log "Adding IPv6 SSH drop rule..."
    ip6tables -A INPUT -p tcp --dport "$SSH_PORT" -m set ! --match-set "$IPSET_NAME_V6" src -j DROP
fi

# Save iptables rules
log "Saving iptables rules..."
iptables-save > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6

log "Cloudflare IP update completed successfully"
echo -e "${CLR_GREEN}Cloudflare IP whitelist updated successfully!${CLR_RESET}"
echo "IPv4 ranges: $IPV4_COUNT"
echo "IPv6 ranges: $IPV6_COUNT"
