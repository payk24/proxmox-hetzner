# =============================================================================
# Post-installation configuration
# =============================================================================

make_template_files() {
    print_info "Modifying template files..."

    print_info "Downloading template files..."
    mkdir -p ./template_files

    download_file "./template_files/99-proxmox.conf" "https://github.com/payk24/proxmox-hetzner/raw/refs/heads/main/template_files/99-proxmox.conf"
    download_file "./template_files/hosts" "https://github.com/payk24/proxmox-hetzner/raw/refs/heads/main/template_files/hosts"
    download_file "./template_files/debian.sources" "https://github.com/payk24/proxmox-hetzner/raw/refs/heads/main/template_files/debian.sources"
    download_file "./template_files/proxmox.sources" "https://github.com/payk24/proxmox-hetzner/raw/refs/heads/main/template_files/proxmox.sources"

    # Security hardening templates
    download_file "./template_files/sshd_config" "https://github.com/payk24/proxmox-hetzner/raw/refs/heads/main/template_files/sshd_config"

    # Download interfaces template based on bridge mode
    local interfaces_template="interfaces.${BRIDGE_MODE:-internal}"
    download_file "./template_files/interfaces" "https://github.com/payk24/proxmox-hetzner/raw/refs/heads/main/template_files/${interfaces_template}"

    # Process hosts file
    print_info "Processing hosts file..."
    sed -i "s|{{MAIN_IPV4}}|$MAIN_IPV4|g" ./template_files/hosts
    sed -i "s|{{FQDN}}|$FQDN|g" ./template_files/hosts
    sed -i "s|{{HOSTNAME}}|$PVE_HOSTNAME|g" ./template_files/hosts
    sed -i "s|{{MAIN_IPV6}}|$MAIN_IPV6|g" ./template_files/hosts

    # Process interfaces file
    print_info "Processing interfaces file (mode: ${BRIDGE_MODE:-internal})..."
    sed -i "s|{{INTERFACE_NAME}}|$INTERFACE_NAME|g" ./template_files/interfaces
    sed -i "s|{{MAIN_IPV4}}|$MAIN_IPV4|g" ./template_files/interfaces
    sed -i "s|{{MAIN_IPV4_GW}}|$MAIN_IPV4_GW|g" ./template_files/interfaces
    sed -i "s|{{MAIN_IPV6}}|$MAIN_IPV6|g" ./template_files/interfaces
    sed -i "s|{{PRIVATE_IP_CIDR}}|$PRIVATE_IP_CIDR|g" ./template_files/interfaces
    sed -i "s|{{PRIVATE_SUBNET}}|$PRIVATE_SUBNET|g" ./template_files/interfaces
    sed -i "s|{{FIRST_IPV6_CIDR}}|$FIRST_IPV6_CIDR|g" ./template_files/interfaces

    print_success "Template files modified"
}

# Configure the installed Proxmox via SSH
configure_proxmox_via_ssh() {
    print_info "Starting post-installation configuration via SSH..."
    make_template_files
    ssh-keygen -f "/root/.ssh/known_hosts" -R "[localhost]:5555" || true

    # Copy template files
    remote_copy "template_files/hosts" "/etc/hosts"
    remote_copy "template_files/interfaces" "/etc/network/interfaces"
    remote_copy "template_files/99-proxmox.conf" "/etc/sysctl.d/99-proxmox.conf"
    remote_copy "template_files/debian.sources" "/etc/apt/sources.list.d/debian.sources"
    remote_copy "template_files/proxmox.sources" "/etc/apt/sources.list.d/proxmox.sources"

    # Basic system configuration
    remote_exec "[ -f /etc/apt/sources.list ] && mv /etc/apt/sources.list /etc/apt/sources.list.bak"
    remote_exec "echo -e 'nameserver 1.1.1.1\nnameserver 1.0.0.1\nnameserver 8.8.8.8\nnameserver 8.8.4.4' > /etc/resolv.conf"
    remote_exec "echo '$PVE_HOSTNAME' > /etc/hostname"
    remote_exec "systemctl disable --now rpcbind rpcbind.socket"

    # Configure ZFS ARC memory limits
    print_info "Configuring ZFS ARC memory limits..."
    remote_exec_script << 'ZFSEOF'
        # Get total RAM in bytes
        TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))

        # Calculate ARC limits (min: 1GB or 10% of RAM, max: 50% of RAM)
        if [ $TOTAL_RAM_GB -ge 128 ]; then
            ARC_MIN=$((16 * 1024 * 1024 * 1024))  # 16GB min for 128GB+ systems
            ARC_MAX=$((64 * 1024 * 1024 * 1024))  # 64GB max
        elif [ $TOTAL_RAM_GB -ge 64 ]; then
            ARC_MIN=$((8 * 1024 * 1024 * 1024))   # 8GB min
            ARC_MAX=$((32 * 1024 * 1024 * 1024))  # 32GB max
        elif [ $TOTAL_RAM_GB -ge 32 ]; then
            ARC_MIN=$((4 * 1024 * 1024 * 1024))   # 4GB min
            ARC_MAX=$((16 * 1024 * 1024 * 1024))  # 16GB max
        else
            ARC_MIN=$((1 * 1024 * 1024 * 1024))   # 1GB min
            ARC_MAX=$((TOTAL_RAM_KB * 1024 / 2))  # 50% of RAM max
        fi

        # Create ZFS configuration
        mkdir -p /etc/modprobe.d
        echo "options zfs zfs_arc_min=$ARC_MIN" > /etc/modprobe.d/zfs.conf
        echo "options zfs zfs_arc_max=$ARC_MAX" >> /etc/modprobe.d/zfs.conf

        echo "ZFS ARC configured: min=$(($ARC_MIN / 1024 / 1024 / 1024))GB, max=$(($ARC_MAX / 1024 / 1024 / 1024))GB"
ZFSEOF

    # Disable enterprise repositories
    print_info "Disabling enterprise repositories..."
    remote_exec_script << 'REPOEOF'
        # Disable ALL enterprise repositories (PVE, Ceph, Ceph-Squid, etc.)
        for repo_file in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
            [ -f "$repo_file" ] || continue
            if grep -q "enterprise.proxmox.com" "$repo_file" 2>/dev/null; then
                mv "$repo_file" "${repo_file}.disabled"
                echo "Disabled $(basename "$repo_file")"
            fi
        done

        # Also check and disable any enterprise sources in main sources.list
        if [ -f /etc/apt/sources.list ] && grep -q "enterprise.proxmox.com" /etc/apt/sources.list 2>/dev/null; then
            sed -i 's|^deb.*enterprise.proxmox.com|# &|g' /etc/apt/sources.list
            echo "Commented out enterprise repos in sources.list"
        fi
REPOEOF

    # Update all system packages
    remote_exec_with_progress "Updating system packages" '
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get dist-upgrade -yqq
        apt-get autoremove -yqq
        apt-get clean
        pveupgrade 2>/dev/null || true
        pveam update 2>/dev/null || true
    '

    # Install monitoring and system utilities
    remote_exec_with_progress "Installing monitoring utilities" '
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -yqq btop iotop ncdu tmux pigz smartmontools jq bat 2>/dev/null || {
            for pkg in btop iotop ncdu tmux pigz smartmontools jq bat; do
                apt-get install -yqq "$pkg" 2>/dev/null || true
            done
        }
        apt-get install -yqq libguestfs-tools 2>/dev/null || true
    '

    # Configure UTF-8 locales
    remote_exec_with_progress "Configuring UTF-8 locales" '
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -yqq locales
        sed -i "s/# en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen
        sed -i "s/# ru_RU.UTF-8/ru_RU.UTF-8/" /etc/locale.gen
        locale-gen
        update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
    '

    # Configure nf_conntrack
    print_info "Configuring nf_conntrack..."
    remote_exec_script << 'CONNTRACKEOF'
        # Add nf_conntrack module to load at boot
        if ! grep -q "nf_conntrack" /etc/modules 2>/dev/null; then
            echo "nf_conntrack" >> /etc/modules
        fi

        # Configure connection tracking limits
        if ! grep -q "nf_conntrack_max" /etc/sysctl.d/99-proxmox.conf 2>/dev/null; then
            echo "net.netfilter.nf_conntrack_max=1048576" >> /etc/sysctl.d/99-proxmox.conf
            echo "net.netfilter.nf_conntrack_tcp_timeout_established=28800" >> /etc/sysctl.d/99-proxmox.conf
        fi

        echo "nf_conntrack configured"
CONNTRACKEOF

    # Configure CPU governor
    remote_exec_with_progress "Configuring CPU governor" '
        apt-get update -qq && apt-get install -yqq cpufrequtils 2>/dev/null || true
        echo "GOVERNOR=\"performance\"" > /etc/default/cpufrequtils
        if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
            for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
                [ -f "$cpu" ] && echo "performance" > "$cpu" 2>/dev/null || true
            done
        fi
    '

    # Remove Proxmox subscription notice
    print_info "Removing Proxmox subscription notice..."
    remote_exec_script << 'SUBEOF'
        if [ -f /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js ]; then
            sed -Ezi.bak "s/(Ext.Msg.show\(\{\s+title: gettext\('No valid sub)/void\(\{ \/\/\1/g" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
            systemctl restart pveproxy.service
            echo "Subscription notice removed"
        else
            echo "proxmoxlib.js not found, skipping"
        fi
SUBEOF

    # Hide Ceph from UI (optional, default: yes)
    if [[ "$HIDE_CEPH" == "yes" ]]; then
        print_info "Hiding Ceph from UI..."
        remote_exec_script << 'CEPHEOF'
            # Create custom CSS to hide Ceph-related UI elements
            CUSTOM_CSS="/usr/share/pve-manager/css/custom.css"
            cat > "$CUSTOM_CSS" << 'CSS'
/* Hide Ceph menu items - not needed for single server */
#pvelogoV { background-image: url(/pve2/images/logo.png) !important; }
.x-treelist-item-text:has-text("Ceph") { display: none !important; }
tr[data-qtip*="Ceph"] { display: none !important; }
CSS

            # Add custom CSS to index template if not already added
            INDEX_TMPL="/usr/share/pve-manager/index.html.tpl"
            if [ -f "$INDEX_TMPL" ] && ! grep -q "custom.css" "$INDEX_TMPL"; then
                sed -i '/<\/head>/i <link rel="stylesheet" type="text/css" href="/pve2/css/custom.css">' "$INDEX_TMPL"
                echo "Custom CSS added to hide Ceph"
            fi

            # Alternative: patch JavaScript to hide Ceph panel completely
            PVE_MANAGER_JS="/usr/share/pve-manager/js/pvemanagerlib.js"
            if [ -f "$PVE_MANAGER_JS" ]; then
                if ! grep -q "// Ceph hidden" "$PVE_MANAGER_JS"; then
                    sed -i "s/itemId: 'ceph'/itemId: 'ceph', hidden: true \/\/ Ceph hidden/g" "$PVE_MANAGER_JS" 2>/dev/null || true
                fi
            fi

            systemctl restart pveproxy.service
            echo "Ceph UI elements hidden"
CEPHEOF
    else
        print_info "Skipping Ceph UI hiding (disabled)"
    fi

    # Install Tailscale if requested
    if [[ "$INSTALL_TAILSCALE" == "yes" ]]; then
        remote_exec_with_progress "Installing Tailscale VPN" '
            curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
            curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list
            apt-get update -qq
            apt-get install -yqq tailscale
            systemctl enable tailscaled
            systemctl start tailscaled
        '

        # Build tailscale up command with selected options
        TAILSCALE_UP_CMD="tailscale up"
        if [[ -n "$TAILSCALE_AUTH_KEY" ]]; then
            TAILSCALE_UP_CMD="$TAILSCALE_UP_CMD --authkey='$TAILSCALE_AUTH_KEY'"
        fi
        if [[ "$TAILSCALE_SSH" == "yes" ]]; then
            TAILSCALE_UP_CMD="$TAILSCALE_UP_CMD --ssh"
        fi

        # If auth key is provided, authenticate Tailscale
        if [[ -n "$TAILSCALE_AUTH_KEY" ]]; then
            print_info "Authenticating Tailscale with provided auth key..."
            remote_exec "$TAILSCALE_UP_CMD"

            # Get Tailscale IP and hostname for display
            TAILSCALE_IP=$(remote_exec "tailscale ip -4" 2>/dev/null || echo "pending")
            TAILSCALE_HOSTNAME=$(remote_exec "tailscale status --json | grep -o '\"DNSName\":\"[^\"]*\"' | head -1 | cut -d'\"' -f4 | sed 's/\\.$//' " 2>/dev/null || echo "")
            print_success "Tailscale authenticated. IP: ${TAILSCALE_IP}"

            # Configure Tailscale Serve for Proxmox Web UI
            if [[ "$TAILSCALE_WEBUI" == "yes" ]]; then
                print_info "Configuring Tailscale Serve for Proxmox Web UI..."
                remote_exec "tailscale serve --bg --https=443 https://127.0.0.1:8006"
                print_success "Proxmox Web UI available via Tailscale Serve"
            fi
        else
            TAILSCALE_IP="not authenticated"
            TAILSCALE_HOSTNAME=""
            print_warning "Tailscale installed but not authenticated."
            print_info "After reboot, run these commands to enable SSH and Web UI:"
            print_info "  tailscale up --ssh"
            print_info "  tailscale serve --bg --https=443 https://127.0.0.1:8006"
        fi
    fi

    # ==========================================================================
    # NTP Synchronization (always enabled)
    # ==========================================================================
    print_info "Configuring NTP time synchronization..."
    remote_exec_script << 'NTPEOF'
        # Enable and configure systemd-timesyncd
        apt-get install -yqq systemd-timesyncd 2>/dev/null || true

        # Configure NTP servers
        mkdir -p /etc/systemd/timesyncd.conf.d
        cat > /etc/systemd/timesyncd.conf.d/local.conf << 'CONF'
[Time]
NTP=0.pool.ntp.org 1.pool.ntp.org 2.pool.ntp.org 3.pool.ntp.org
FallbackNTP=ntp.ubuntu.com time.cloudflare.com
CONF

        # Enable and start timesyncd
        systemctl enable systemd-timesyncd
        systemctl restart systemd-timesyncd

        # Set hardware clock from system time
        hwclock --systohc 2>/dev/null || true

        echo "NTP synchronization configured"
NTPEOF
    print_success "NTP time synchronization configured"

    # ==========================================================================
    # Journald Optimization (optional, default: yes)
    # ==========================================================================
    if [[ "$OPTIMIZE_JOURNALD" == "yes" ]]; then
        print_info "Optimizing journald log settings..."
        remote_exec_script << 'JOURNALDEOF'
            mkdir -p /etc/systemd/journald.conf.d
            cat > /etc/systemd/journald.conf.d/size-limit.conf << 'CONF'
[Journal]
# Limit journal size to prevent disk fill
SystemMaxUse=1G
SystemKeepFree=2G
SystemMaxFileSize=100M
MaxRetentionSec=1month
MaxFileSec=1week
Compress=yes
CONF

            # Restart journald to apply changes
            systemctl restart systemd-journald

            # Clean up old logs
            journalctl --vacuum-size=500M 2>/dev/null || true

            echo "Journald optimized: max 1GB, 1 month retention"
JOURNALDEOF
        print_success "Journald optimization configured"
    fi

    # ==========================================================================
    # Unattended Upgrades (optional, default: yes)
    # ==========================================================================
    if [[ "$INSTALL_UNATTENDED_UPGRADES" == "yes" ]]; then
        remote_exec_with_progress "Configuring unattended security upgrades" '
            export DEBIAN_FRONTEND=noninteractive
            apt-get install -yqq unattended-upgrades apt-listchanges

            # Enable unattended upgrades
            cat > /etc/apt/apt.conf.d/20auto-upgrades << EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

            # Configure what to upgrade
            cat > /etc/apt/apt.conf.d/50unattended-upgrades << EOF
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}";
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}:\${distro_codename}-updates";
    "Proxmox:bookworm";
};
Unattended-Upgrade::Package-Blacklist {
    "proxmox-ve";
    "pve-kernel-*";
};
Unattended-Upgrade::DevRelease "false";
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

            # Enable the service
            systemctl enable unattended-upgrades
            systemctl start unattended-upgrades

            echo "Unattended upgrades configured (security + updates, kernel excluded)"
        '
    fi

    # ==========================================================================
    # Custom MOTD (optional, default: yes)
    # ==========================================================================
    if [[ "$INSTALL_MOTD" == "yes" ]]; then
        print_info "Configuring custom MOTD..."
        remote_exec_script << 'MOTDEOF'
            # Disable default MOTD components
            chmod -x /etc/update-motd.d/* 2>/dev/null || true

            # Create custom MOTD script
            cat > /etc/update-motd.d/00-proxmox-info << 'SCRIPT'
#!/bin/bash
# Proxmox System Information MOTD

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Get system info
HOSTNAME=$(hostname)
UPTIME=$(uptime -p | sed 's/up //')
LOAD=$(cat /proc/loadavg | awk '{print $1", "$2", "$3}')
KERNEL=$(uname -r)

# CPU info
CPU_MODEL=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
CPU_CORES=$(nproc)
CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print 100 - $8}' | cut -d. -f1)

# Memory info
MEM_TOTAL=$(free -h | awk '/^Mem:/ {print $2}')
MEM_USED=$(free -h | awk '/^Mem:/ {print $3}')
MEM_PERCENT=$(free | awk '/^Mem:/ {printf "%.0f", $3/$2 * 100}')

# ZFS info
if command -v zpool &> /dev/null; then
    ZFS_POOL=$(zpool list -H -o name 2>/dev/null | head -1)
    if [ -n "$ZFS_POOL" ]; then
        ZFS_SIZE=$(zpool list -H -o size "$ZFS_POOL" 2>/dev/null)
        ZFS_USED=$(zpool list -H -o allocated "$ZFS_POOL" 2>/dev/null)
        ZFS_FREE=$(zpool list -H -o free "$ZFS_POOL" 2>/dev/null)
        ZFS_HEALTH=$(zpool list -H -o health "$ZFS_POOL" 2>/dev/null)
    fi
fi

# VM/CT counts
VMS=$(qm list 2>/dev/null | tail -n +2 | wc -l)
CTS=$(pct list 2>/dev/null | tail -n +2 | wc -l)
RUNNING_VMS=$(qm list 2>/dev/null | grep running | wc -l)
RUNNING_CTS=$(pct list 2>/dev/null | grep running | wc -l)

# Network info
IP_ADDR=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║${NC}              ${BLUE}${BOLD}Proxmox VE - ${HOSTNAME}${NC}              ${CYAN}${BOLD}║${NC}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}System:${NC}"
echo -e "  Kernel:    ${KERNEL}"
echo -e "  Uptime:    ${UPTIME}"
echo -e "  Load:      ${LOAD}"
echo -e "  IP:        ${IP_ADDR}"
echo ""
echo -e "${BOLD}Resources:${NC}"
if [ "$CPU_USAGE" -gt 80 ]; then
    echo -e "  CPU:       ${RED}${CPU_USAGE}%${NC} (${CPU_CORES} cores)"
elif [ "$CPU_USAGE" -gt 50 ]; then
    echo -e "  CPU:       ${YELLOW}${CPU_USAGE}%${NC} (${CPU_CORES} cores)"
else
    echo -e "  CPU:       ${GREEN}${CPU_USAGE}%${NC} (${CPU_CORES} cores)"
fi

if [ "$MEM_PERCENT" -gt 80 ]; then
    echo -e "  Memory:    ${RED}${MEM_USED}/${MEM_TOTAL} (${MEM_PERCENT}%)${NC}"
elif [ "$MEM_PERCENT" -gt 50 ]; then
    echo -e "  Memory:    ${YELLOW}${MEM_USED}/${MEM_TOTAL} (${MEM_PERCENT}%)${NC}"
else
    echo -e "  Memory:    ${GREEN}${MEM_USED}/${MEM_TOTAL} (${MEM_PERCENT}%)${NC}"
fi

if [ -n "$ZFS_POOL" ]; then
    echo ""
    echo -e "${BOLD}ZFS Pool (${ZFS_POOL}):${NC}"
    if [ "$ZFS_HEALTH" = "ONLINE" ]; then
        echo -e "  Health:    ${GREEN}${ZFS_HEALTH}${NC}"
    else
        echo -e "  Health:    ${RED}${ZFS_HEALTH}${NC}"
    fi
    echo -e "  Used:      ${ZFS_USED} / ${ZFS_SIZE} (Free: ${ZFS_FREE})"
fi

echo ""
echo -e "${BOLD}Virtualization:${NC}"
echo -e "  VMs:       ${VMS} total, ${GREEN}${RUNNING_VMS} running${NC}"
echo -e "  CTs:       ${CTS} total, ${GREEN}${RUNNING_CTS} running${NC}"
echo ""
SCRIPT

            chmod +x /etc/update-motd.d/00-proxmox-info

            # Disable last login message
            sed -i 's/^#*PrintLastLog.*/PrintLastLog no/' /etc/ssh/sshd_config 2>/dev/null || true

            echo "Custom MOTD configured"
MOTDEOF
        print_success "Custom MOTD configured"
    fi

    # ==========================================================================
    # Fail2ban (optional, default: no)
    # ==========================================================================
    if [[ "$INSTALL_FAIL2BAN" == "yes" ]]; then
        remote_exec_with_progress "Installing and configuring Fail2ban" '
            export DEBIAN_FRONTEND=noninteractive
            apt-get install -yqq fail2ban

            # Create Proxmox-specific jail configuration
            cat > /etc/fail2ban/jail.d/proxmox.conf << EOF
[DEFAULT]
# Ban hosts for 1 hour
bantime = 3600
# Find failures within 10 minutes
findtime = 600
# Allow 5 retries before ban
maxretry = 5
# Ignore local networks
ignoreip = 127.0.0.1/8 ::1 10.0.0.0/8 192.168.0.0/16 172.16.0.0/12

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600

[proxmox]
enabled = true
port = https,http,8006
filter = proxmox
logpath = /var/log/daemon.log
maxretry = 3
bantime = 3600
EOF

            # Create Proxmox filter
            cat > /etc/fail2ban/filter.d/proxmox.conf << EOF
[Definition]
failregex = pvedaemon\[.*authentication failure; rhost=<HOST> user=.* msg=.*
ignoreregex =
EOF

            # Enable and start fail2ban
            systemctl enable fail2ban
            systemctl restart fail2ban

            echo "Fail2ban configured with SSH and Proxmox jails"
        '
    fi

    # ==========================================================================
    # Basic Firewall (optional, default: no)
    # ==========================================================================
    if [[ "$INSTALL_FIREWALL" == "yes" ]]; then
        print_info "Configuring basic firewall rules..."
        remote_exec_script << 'FWEOF'
            export DEBIAN_FRONTEND=noninteractive
            apt-get install -yqq iptables-persistent netfilter-persistent

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

            # Log dropped packets (optional, can be noisy)
            # iptables -A INPUT -j LOG --log-prefix "IPTables-Dropped: "

            # Save rules
            netfilter-persistent save

            # IPv6 rules (similar)
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

            netfilter-persistent save

            echo "Firewall configured: SSH(22), PVE Web(8006), VNC, Spice allowed"
FWEOF
        print_success "Basic firewall configured"
    fi

    # ==========================================================================
    # PCI Passthrough Preparation (optional, default: no)
    # ==========================================================================
    if [[ "$ENABLE_PCI_PASSTHROUGH" == "yes" ]]; then
        print_info "Configuring PCI passthrough (IOMMU)..."
        remote_exec_script << 'IOMMUEOF'
            # Detect CPU vendor
            if grep -q "GenuineIntel" /proc/cpuinfo; then
                IOMMU_PARAM="intel_iommu=on"
            elif grep -q "AuthenticAMD" /proc/cpuinfo; then
                IOMMU_PARAM="amd_iommu=on"
            else
                echo "Unknown CPU vendor, using intel_iommu"
                IOMMU_PARAM="intel_iommu=on"
            fi

            # Update GRUB configuration
            GRUB_FILE="/etc/default/grub"
            if [ -f "$GRUB_FILE" ]; then
                # Backup original
                cp "$GRUB_FILE" "${GRUB_FILE}.bak"

                # Add IOMMU parameters if not present
                if ! grep -q "iommu=on" "$GRUB_FILE"; then
                    sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"/GRUB_CMDLINE_LINUX_DEFAULT=\"${IOMMU_PARAM} iommu=pt /" "$GRUB_FILE"
                fi

                # Update GRUB
                update-grub
                echo "GRUB updated with IOMMU parameters"
            fi

            # Add VFIO modules
            cat > /etc/modules-load.d/vfio.conf << 'MODULES'
vfio
vfio_iommu_type1
vfio_pci
vfio_virqfd
MODULES

            # Blacklist GPU drivers for passthrough (commented by default)
            cat > /etc/modprobe.d/pci-passthrough.conf << 'BLACKLIST'
# Uncomment to blacklist drivers for GPU passthrough
# blacklist nouveau
# blacklist nvidia
# blacklist nvidiafb
# blacklist radeon
# blacklist amdgpu

# VFIO options
options vfio-pci ids=
BLACKLIST

            echo "PCI passthrough prepared. Reboot required to enable IOMMU."
            echo "To passthrough a device:"
            echo "1. Find device ID: lspci -nn"
            echo "2. Add ID to /etc/modprobe.d/pci-passthrough.conf"
            echo "3. Regenerate initramfs: update-initramfs -u -k all"
IOMMUEOF
        print_success "PCI passthrough prepared (reboot required)"
    fi

    # ==========================================================================
    # Let's Encrypt Certificate (optional, default: no)
    # ==========================================================================
    if [[ "$INSTALL_LETSENCRYPT" == "yes" && -n "$LETSENCRYPT_DOMAIN" ]]; then
        print_info "Configuring Let's Encrypt for ${LETSENCRYPT_DOMAIN}..."
        remote_exec_script << LEEOF
            export DEBIAN_FRONTEND=noninteractive

            # Install pve-acme for Proxmox ACME integration
            apt-get install -yqq pve-acme 2>/dev/null || true

            # Register ACME account if not exists
            if ! pvenode acme account list 2>/dev/null | grep -q "default"; then
                pvenode acme account register default --contact "${EMAIL}" --directory https://acme-v02.api.letsencrypt.org/directory
                echo "ACME account registered"
            fi

            # Configure domain for certificate
            pvenode config set --acme "domains=${LETSENCRYPT_DOMAIN}"

            # Order certificate
            if pvenode acme cert order 2>/dev/null; then
                echo "Let's Encrypt certificate obtained for ${LETSENCRYPT_DOMAIN}"

                # Setup auto-renewal cron
                if ! grep -q "pvenode acme cert renew" /etc/crontab 2>/dev/null; then
                    echo "0 3 * * * root pvenode acme cert renew --force 2>/dev/null" >> /etc/crontab
                    echo "Auto-renewal cron job added"
                fi
            else
                echo "Warning: Could not obtain certificate. Ensure DNS points to this server."
                echo "Run manually after reboot: pvenode acme cert order"
            fi
LEEOF
        print_success "Let's Encrypt configured for ${LETSENCRYPT_DOMAIN}"
    fi

    # Deploy SSH hardening LAST (after all other operations)
    print_info "Deploying SSH hardening..."

    # Deploy SSH public key FIRST (before disabling password auth!)
    remote_exec "mkdir -p /root/.ssh && chmod 700 /root/.ssh"
    remote_exec "echo '$SSH_PUBLIC_KEY' >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys"
    remote_copy "template_files/sshd_config" "/etc/ssh/sshd_config"

    print_success "Security hardening configured"

    # Power off the VM
    print_info "Powering off the VM..."
    remote_exec "poweroff" || true

    # Wait for QEMU to exit
    print_info "Waiting for QEMU process to exit..."
    wait $QEMU_PID || true
    print_success "QEMU process exited"
}
