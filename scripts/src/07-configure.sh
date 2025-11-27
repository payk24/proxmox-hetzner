# =============================================================================
# Post-installation configuration
# =============================================================================

make_template_files() {
    echo -e "${CLR_BLUE}Modifying template files...${CLR_RESET}"

    echo -e "${CLR_YELLOW}Downloading template files...${CLR_RESET}"
    mkdir -p ./template_files

    download_file "./template_files/99-proxmox.conf" "https://github.com/payk24/proxmox-hetzner/raw/refs/heads/main/template_files/99-proxmox.conf"
    download_file "./template_files/hosts" "https://github.com/payk24/proxmox-hetzner/raw/refs/heads/main/template_files/hosts"
    download_file "./template_files/interfaces" "https://github.com/payk24/proxmox-hetzner/raw/refs/heads/main/template_files/interfaces"
    download_file "./template_files/debian.sources" "https://github.com/payk24/proxmox-hetzner/raw/refs/heads/main/template_files/debian.sources"
    download_file "./template_files/proxmox.sources" "https://github.com/payk24/proxmox-hetzner/raw/refs/heads/main/template_files/proxmox.sources"

    # Security hardening templates
    download_file "./template_files/sshd_config" "https://github.com/payk24/proxmox-hetzner/raw/refs/heads/main/template_files/sshd_config"

    # Process hosts file
    echo -e "${CLR_YELLOW}Processing hosts file...${CLR_RESET}"
    sed -i "s|{{MAIN_IPV4}}|$MAIN_IPV4|g" ./template_files/hosts
    sed -i "s|{{FQDN}}|$FQDN|g" ./template_files/hosts
    sed -i "s|{{HOSTNAME}}|$HOSTNAME|g" ./template_files/hosts
    sed -i "s|{{MAIN_IPV6}}|$MAIN_IPV6|g" ./template_files/hosts

    # Process interfaces file
    echo -e "${CLR_YELLOW}Processing interfaces file...${CLR_RESET}"
    sed -i "s|{{INTERFACE_NAME}}|$INTERFACE_NAME|g" ./template_files/interfaces
    sed -i "s|{{MAIN_IPV4}}|$MAIN_IPV4|g" ./template_files/interfaces
    sed -i "s|{{MAIN_IPV4_GW}}|$MAIN_IPV4_GW|g" ./template_files/interfaces
    sed -i "s|{{MAIN_IPV6}}|$MAIN_IPV6|g" ./template_files/interfaces
    sed -i "s|{{PRIVATE_IP_CIDR}}|$PRIVATE_IP_CIDR|g" ./template_files/interfaces
    sed -i "s|{{PRIVATE_SUBNET}}|$PRIVATE_SUBNET|g" ./template_files/interfaces
    sed -i "s|{{FIRST_IPV6_CIDR}}|$FIRST_IPV6_CIDR|g" ./template_files/interfaces

    echo -e "${CLR_GREEN}✓ Template files modified${CLR_RESET}"
}

# Configure the installed Proxmox via SSH
configure_proxmox_via_ssh() {
    echo -e "${CLR_BLUE}Starting post-installation configuration via SSH...${CLR_RESET}"
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
    remote_exec "echo '$HOSTNAME' > /etc/hostname"
    remote_exec "systemctl disable --now rpcbind rpcbind.socket"

    # Configure ZFS ARC memory limits
    echo -e "${CLR_YELLOW}Configuring ZFS ARC memory limits...${CLR_RESET}"
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
    echo -e "${CLR_YELLOW}Disabling enterprise repositories...${CLR_RESET}"
    remote_exec_script << 'REPOEOF'
        # Disable ALL enterprise repositories (PVE, Ceph, Ceph-Squid, etc.)
        # These require a paid subscription and cause 401 errors
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

    # Configure nf_conntrack
    echo -e "${CLR_YELLOW}Configuring nf_conntrack...${CLR_RESET}"
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
    echo -e "${CLR_YELLOW}Removing Proxmox subscription notice...${CLR_RESET}"
    remote_exec_script << 'SUBEOF'
        if [ -f /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js ]; then
            sed -Ezi.bak "s/(Ext.Msg.show\(\{\s+title: gettext\('No valid sub)/void\(\{ \/\/\1/g" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
            systemctl restart pveproxy.service
            echo "Subscription notice removed"
        else
            echo "proxmoxlib.js not found, skipping"
        fi
SUBEOF

    # Hide Ceph from UI (not needed for single-server setup)
    echo -e "${CLR_YELLOW}Hiding Ceph from UI...${CLR_RESET}"
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
            # Hide Ceph from node tree navigation
            if ! grep -q "// Ceph hidden" "$PVE_MANAGER_JS"; then
                sed -i "s/itemId: 'ceph'/itemId: 'ceph', hidden: true \/\/ Ceph hidden/g" "$PVE_MANAGER_JS" 2>/dev/null || true
            fi
        fi

        systemctl restart pveproxy.service
        echo "Ceph UI elements hidden"
CEPHEOF

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
            echo -e "${CLR_YELLOW}Authenticating Tailscale with provided auth key...${CLR_RESET}"
            remote_exec "$TAILSCALE_UP_CMD"

            # Get Tailscale IP and hostname for display
            TAILSCALE_IP=$(remote_exec "tailscale ip -4" 2>/dev/null || echo "pending")
            TAILSCALE_HOSTNAME=$(remote_exec "tailscale status --json | grep -o '\"DNSName\":\"[^\"]*\"' | head -1 | cut -d'\"' -f4 | sed 's/\\.$//' " 2>/dev/null || echo "")
            echo -e "${CLR_GREEN}✓ Tailscale authenticated. IP: ${TAILSCALE_IP}${CLR_RESET}"

            # Configure Tailscale Serve for Proxmox Web UI
            if [[ "$TAILSCALE_WEBUI" == "yes" ]]; then
                echo -e "${CLR_YELLOW}Configuring Tailscale Serve for Proxmox Web UI...${CLR_RESET}"
                remote_exec "tailscale serve --bg --https=443 https://127.0.0.1:8006"
                echo -e "${CLR_GREEN}✓ Proxmox Web UI available via Tailscale Serve${CLR_RESET}"
            fi
        else
            TAILSCALE_IP="not authenticated"
            TAILSCALE_HOSTNAME=""
            echo -e "${CLR_YELLOW}Tailscale installed but not authenticated.${CLR_RESET}"
            echo -e "${CLR_YELLOW}After reboot, run these commands to enable SSH and Web UI:${CLR_RESET}"
            echo -e "${CLR_YELLOW}  tailscale up --ssh${CLR_RESET}"
            echo -e "${CLR_YELLOW}  tailscale serve --bg --https=443 https://127.0.0.1:8006${CLR_RESET}"
        fi
    fi

    # Deploy SSH hardening LAST (after all other operations)
    echo -e "${CLR_YELLOW}Deploying SSH hardening...${CLR_RESET}"

    # Deploy SSH public key FIRST (before disabling password auth!)
    remote_exec "mkdir -p /root/.ssh && chmod 700 /root/.ssh"
    remote_exec "echo '$SSH_PUBLIC_KEY' >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys"
    remote_copy "template_files/sshd_config" "/etc/ssh/sshd_config"

    echo -e "${CLR_GREEN}✓ Security hardening configured${CLR_RESET}"

    # Power off the VM
    echo -e "${CLR_YELLOW}Powering off the VM...${CLR_RESET}"
    remote_exec "poweroff" || true

    # Wait for QEMU to exit
    echo -e "${CLR_YELLOW}Waiting for QEMU process to exit...${CLR_RESET}"
    wait $QEMU_PID || true
    echo -e "${CLR_GREEN}✓ QEMU process exited${CLR_RESET}"
}
