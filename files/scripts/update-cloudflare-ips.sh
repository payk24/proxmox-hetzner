#!/bin/bash
# ============================================
# Cloudflare IP Whitelist Updater
# Restricts SSH, HTTP, and HTTPS to Cloudflare IPs only
# Run via cron: 0 */6 * * * /usr/local/bin/update-cloudflare-ips.sh
# ============================================

set -euo pipefail

# ============================================
# Configuration
# ============================================
CLOUDFLARE_IPV4_URL="https://www.cloudflare.com/ips-v4"
CLOUDFLARE_IPV6_URL="https://www.cloudflare.com/ips-v6"
IPSET_NAME_V4="cloudflare-ipv4"
IPSET_NAME_V6="cloudflare-ipv6"
LOG_FILE="/var/log/cloudflare-ip-update.log"

# Ports to restrict to Cloudflare IPs only
# SSH (22), HTTP (80), HTTPS (443)
CLOUDFLARE_PORTS=(22 80 443)

# Retry settings
MAX_RETRIES=3
RETRY_DELAY=5

# ============================================
# Colors and logging
# ============================================
CLR_GREEN="\033[1;32m"
CLR_YELLOW="\033[1;33m"
CLR_RED="\033[1;31m"
CLR_BLUE="\033[1;34m"
CLR_RESET="\033[m"

log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}

log_info() { log "INFO" "$1"; }
log_warn() { log "WARN" "$1"; }
log_error() { log "ERROR" "$1"; }

error_exit() {
    echo -e "${CLR_RED}ERROR: $1${CLR_RESET}" >&2
    log_error "$1"
    exit 1
}

# ============================================
# Pre-flight checks
# ============================================
if [[ $EUID -ne 0 ]]; then
    error_exit "This script must be run as root"
fi

# Ensure required tools are installed
install_dependencies() {
    local packages_needed=()

    command -v ipset &>/dev/null || packages_needed+=("ipset")
    command -v curl &>/dev/null || packages_needed+=("curl")

    if [[ ${#packages_needed[@]} -gt 0 ]]; then
        log_info "Installing dependencies: ${packages_needed[*]}"
        apt-get update -qq
        apt-get install -yqq "${packages_needed[@]}" iptables-persistent
    fi
}

install_dependencies

# ============================================
# Fetch Cloudflare IPs with retry
# ============================================
fetch_with_retry() {
    local url="$1"
    local attempt=1
    local result=""

    while [[ $attempt -le $MAX_RETRIES ]]; do
        if result=$(curl -sf --connect-timeout 10 --max-time 30 "$url" 2>/dev/null); then
            if [[ -n "$result" ]]; then
                echo "$result"
                return 0
            fi
        fi

        log_warn "Fetch attempt $attempt/$MAX_RETRIES failed for $url"
        ((attempt++))
        [[ $attempt -le $MAX_RETRIES ]] && sleep $RETRY_DELAY
    done

    return 1
}

log_info "============================================"
log_info "Starting Cloudflare IP update"
log_info "============================================"

# Fetch IPv4 ranges
log_info "Fetching Cloudflare IPv4 ranges..."
CF_IPV4=$(fetch_with_retry "$CLOUDFLARE_IPV4_URL") || error_exit "Failed to fetch Cloudflare IPv4 ranges after $MAX_RETRIES attempts"

# Fetch IPv6 ranges
log_info "Fetching Cloudflare IPv6 ranges..."
CF_IPV6=$(fetch_with_retry "$CLOUDFLARE_IPV6_URL") || error_exit "Failed to fetch Cloudflare IPv6 ranges after $MAX_RETRIES attempts"

# Validate data
[[ -z "$CF_IPV4" ]] && error_exit "Cloudflare IPv4 list is empty"
[[ -z "$CF_IPV6" ]] && error_exit "Cloudflare IPv6 list is empty"

# Count ranges
IPV4_COUNT=$(echo "$CF_IPV4" | wc -l)
IPV6_COUNT=$(echo "$CF_IPV6" | wc -l)
log_info "Retrieved $IPV4_COUNT IPv4 ranges and $IPV6_COUNT IPv6 ranges"

# ============================================
# Update ipsets
# ============================================
TEMP_V4="${IPSET_NAME_V4}-temp"
TEMP_V6="${IPSET_NAME_V6}-temp"

# Cleanup temp sets
ipset destroy "$TEMP_V4" 2>/dev/null || true
ipset destroy "$TEMP_V6" 2>/dev/null || true

# Create IPv4 ipset
log_info "Creating IPv4 ipset..."
ipset create "$TEMP_V4" hash:net family inet hashsize 1024 maxelem 65536

while IFS= read -r ip; do
    [[ -n "$ip" ]] && ipset add "$TEMP_V4" "$ip" 2>/dev/null || true
done <<< "$CF_IPV4"

# Create IPv6 ipset
log_info "Creating IPv6 ipset..."
ipset create "$TEMP_V6" hash:net family inet6 hashsize 1024 maxelem 65536

while IFS= read -r ip; do
    [[ -n "$ip" ]] && ipset add "$TEMP_V6" "$ip" 2>/dev/null || true
done <<< "$CF_IPV6"

# Create main sets if they don't exist, then swap atomically
log_info "Swapping ipsets atomically..."

ipset list "$IPSET_NAME_V4" &>/dev/null || \
    ipset create "$IPSET_NAME_V4" hash:net family inet hashsize 1024 maxelem 65536

ipset list "$IPSET_NAME_V6" &>/dev/null || \
    ipset create "$IPSET_NAME_V6" hash:net family inet6 hashsize 1024 maxelem 65536

ipset swap "$TEMP_V4" "$IPSET_NAME_V4"
ipset swap "$TEMP_V6" "$IPSET_NAME_V6"

# Cleanup
ipset destroy "$TEMP_V4"
ipset destroy "$TEMP_V6"

# Save ipsets for persistence
mkdir -p /etc/iptables
ipset save > /etc/ipset.conf

# ============================================
# Configure iptables rules
# ============================================
log_info "Configuring iptables rules for ports: ${CLOUDFLARE_PORTS[*]}"

# Function to add rules for a specific port
add_port_rules() {
    local port="$1"
    local ipset_v4="$IPSET_NAME_V4"
    local ipset_v6="$IPSET_NAME_V6"

    # IPv4: Accept from Cloudflare
    if ! iptables -C INPUT -p tcp --dport "$port" -m set --match-set "$ipset_v4" src -j ACCEPT 2>/dev/null; then
        log_info "Adding IPv4 ACCEPT rule for port $port"
        iptables -I INPUT 1 -p tcp --dport "$port" -m set --match-set "$ipset_v4" src -j ACCEPT
    fi

    # IPv4: Drop from non-Cloudflare
    if ! iptables -C INPUT -p tcp --dport "$port" -m set ! --match-set "$ipset_v4" src -j DROP 2>/dev/null; then
        log_info "Adding IPv4 DROP rule for port $port"
        iptables -A INPUT -p tcp --dport "$port" -m set ! --match-set "$ipset_v4" src -j DROP
    fi

    # IPv6: Accept from Cloudflare
    if ! ip6tables -C INPUT -p tcp --dport "$port" -m set --match-set "$ipset_v6" src -j ACCEPT 2>/dev/null; then
        log_info "Adding IPv6 ACCEPT rule for port $port"
        ip6tables -I INPUT 1 -p tcp --dport "$port" -m set --match-set "$ipset_v6" src -j ACCEPT
    fi

    # IPv6: Drop from non-Cloudflare
    if ! ip6tables -C INPUT -p tcp --dport "$port" -m set ! --match-set "$ipset_v6" src -j DROP 2>/dev/null; then
        log_info "Adding IPv6 DROP rule for port $port"
        ip6tables -A INPUT -p tcp --dport "$port" -m set ! --match-set "$ipset_v6" src -j DROP
    fi
}

# Apply rules for each protected port
for port in "${CLOUDFLARE_PORTS[@]}"; do
    add_port_rules "$port"
done

# Save iptables rules for persistence
log_info "Saving iptables rules..."
iptables-save > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6

# ============================================
# Create systemd service for ipset restore on boot
# ============================================
if [[ ! -f /etc/systemd/system/ipset-restore.service ]]; then
    log_info "Creating ipset restore systemd service..."
    cat > /etc/systemd/system/ipset-restore.service << 'SYSTEMD'
[Unit]
Description=Restore ipset rules
Before=netfilter-persistent.service
Before=iptables.service

[Service]
Type=oneshot
ExecStart=/sbin/ipset restore -f /etc/ipset.conf
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SYSTEMD
    systemctl daemon-reload
    systemctl enable ipset-restore.service
fi

# ============================================
# Summary
# ============================================
log_info "============================================"
log_info "Cloudflare IP update completed successfully"
log_info "============================================"

echo ""
echo -e "${CLR_GREEN}Cloudflare IP whitelist updated successfully!${CLR_RESET}"
echo ""
echo -e "${CLR_BLUE}Protected ports:${CLR_RESET}"
for port in "${CLOUDFLARE_PORTS[@]}"; do
    case $port in
        22)  echo "  - Port 22 (SSH)" ;;
        80)  echo "  - Port 80 (HTTP)" ;;
        443) echo "  - Port 443 (HTTPS)" ;;
        *)   echo "  - Port $port" ;;
    esac
done
echo ""
echo -e "${CLR_YELLOW}Cloudflare ranges:${CLR_RESET}"
echo "  - IPv4: $IPV4_COUNT ranges"
echo "  - IPv6: $IPV6_COUNT ranges"
echo ""
echo -e "${CLR_YELLOW}Next update:${CLR_RESET} Cron runs every 6 hours"
