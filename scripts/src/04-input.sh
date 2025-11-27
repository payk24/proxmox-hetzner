# =============================================================================
# User input functions
# =============================================================================

# Helper to prompt or use existing value
prompt_or_default() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    local current_value="${!var_name}"

    if [[ "$NON_INTERACTIVE" == true ]]; then
        if [[ -n "$current_value" ]]; then
            echo "$current_value"
        else
            echo "$default"
        fi
    else
        local result
        read -e -p "$prompt" -i "${current_value:-$default}" result
        echo "$result"
    fi
}

get_system_inputs() {
    # Get default interface name (the one with default route)
    CURRENT_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
    if [ -z "$CURRENT_INTERFACE" ]; then
        CURRENT_INTERFACE="eth0"
    fi

    # CRITICAL: Get the predictable interface name for bare metal
    # Rescue System often uses eth0, but Proxmox uses predictable naming (enp0s4, eno1, etc.)
    # We must use the predictable name in the config, otherwise network won't work after reboot
    PREDICTABLE_NAME=""

    # Try to get predictable name from udev
    if [ -e "/sys/class/net/${CURRENT_INTERFACE}" ]; then
        # Try ID_NET_NAME_PATH first (most reliable for PCIe devices)
        PREDICTABLE_NAME=$(udevadm info "/sys/class/net/${CURRENT_INTERFACE}" 2>/dev/null | grep "ID_NET_NAME_PATH=" | cut -d'=' -f2)

        # Fallback to ID_NET_NAME_ONBOARD (for onboard NICs)
        if [ -z "$PREDICTABLE_NAME" ]; then
            PREDICTABLE_NAME=$(udevadm info "/sys/class/net/${CURRENT_INTERFACE}" 2>/dev/null | grep "ID_NET_NAME_ONBOARD=" | cut -d'=' -f2)
        fi

        # Fallback to altname from ip link
        if [ -z "$PREDICTABLE_NAME" ]; then
            PREDICTABLE_NAME=$(ip -d link show "$CURRENT_INTERFACE" 2>/dev/null | grep "altname" | awk '{print $2}' | head -1)
        fi
    fi

    # Use predictable name if found, otherwise fall back to current interface name
    if [ -n "$PREDICTABLE_NAME" ]; then
        DEFAULT_INTERFACE="$PREDICTABLE_NAME"
        echo -e "${CLR_GREEN}Detected predictable interface name: ${PREDICTABLE_NAME} (current: ${CURRENT_INTERFACE})${CLR_RESET}"
    else
        DEFAULT_INTERFACE="$CURRENT_INTERFACE"
        echo -e "${CLR_YELLOW}Warning: Could not detect predictable name, using: ${CURRENT_INTERFACE}${CLR_RESET}"
    fi

    # Get all available interfaces and their altnames for display
    AVAILABLE_ALTNAMES=$(ip -d link show | grep -v "lo:" | grep -E '(^[0-9]+:|altname)' | awk '/^[0-9]+:/ {interface=$2; gsub(/:/, "", interface); printf "%s", interface} /altname/ {printf ", %s", $2} END {print ""}' | sed 's/, $//')

    # Set INTERFACE_NAME to default if not already set
    if [ -z "$INTERFACE_NAME" ]; then
        INTERFACE_NAME="$DEFAULT_INTERFACE"
    fi

    # Prompt user for interface name
    if [[ "$NON_INTERACTIVE" != true ]]; then
        echo -e "${CLR_YELLOW}NOTE: Use the predictable name (enp*, eno*) for bare metal, not eth0${CLR_RESET}"
        read -e -p "Interface name (options are: ${AVAILABLE_ALTNAMES}) : " -i "$INTERFACE_NAME" INTERFACE_NAME
    fi

    # Get network information from the CURRENT interface (the one active in Rescue)
    # but use INTERFACE_NAME (predictable name) for the Proxmox configuration
    MAIN_IPV4_CIDR=$(ip address show "$CURRENT_INTERFACE" | grep global | grep "inet " | xargs | cut -d" " -f2)
    MAIN_IPV4=$(echo "$MAIN_IPV4_CIDR" | cut -d'/' -f1)
    MAIN_IPV4_GW=$(ip route | grep default | xargs | cut -d" " -f3)
    MAC_ADDRESS=$(ip link show "$CURRENT_INTERFACE" | awk '/ether/ {print $2}')
    IPV6_CIDR=$(ip address show "$CURRENT_INTERFACE" | grep global | grep "inet6 " | xargs | cut -d" " -f2)
    MAIN_IPV6=$(echo "$IPV6_CIDR" | cut -d'/' -f1)

    # Set a default value for FIRST_IPV6_CIDR even if IPV6_CIDR is empty
    if [ -n "$IPV6_CIDR" ]; then
        FIRST_IPV6_CIDR="$(echo "$IPV6_CIDR" | cut -d'/' -f1 | cut -d':' -f1-4):1::1/80"
    else
        FIRST_IPV6_CIDR=""
    fi

    # Display detected information
    echo -e "${CLR_YELLOW}Detected Network Information:${CLR_RESET}"
    echo "Current Interface (Rescue): $CURRENT_INTERFACE"
    echo "Config Interface (Proxmox): $INTERFACE_NAME"
    echo "Main IPv4 CIDR: $MAIN_IPV4_CIDR"
    echo "Main IPv4: $MAIN_IPV4"
    echo "Main IPv4 Gateway: $MAIN_IPV4_GW"
    echo "MAC Address: $MAC_ADDRESS"
    echo "IPv6 CIDR: $IPV6_CIDR"
    echo "IPv6: $MAIN_IPV6"

    # Get user input for other configuration with validation
    # Note: PVE_HOSTNAME is used instead of HOSTNAME to avoid conflict with bash built-in
    if [[ "$NON_INTERACTIVE" == true ]]; then
        # Use defaults or config values in non-interactive mode
        PVE_HOSTNAME="${PVE_HOSTNAME:-pve}"
        DOMAIN_SUFFIX="${DOMAIN_SUFFIX:-local}"
        TIMEZONE="${TIMEZONE:-Europe/Kyiv}"
        EMAIL="${EMAIL:-admin@example.com}"
        PRIVATE_SUBNET="${PRIVATE_SUBNET:-10.0.0.0/24}"
    else
        while true; do
            read -e -p "Enter your hostname (e.g., pve, proxmox): " -i "${PVE_HOSTNAME:-pve}" PVE_HOSTNAME
            if validate_hostname "$PVE_HOSTNAME"; then
                break
            fi
            echo -e "${CLR_RED}Invalid hostname. Use only letters, numbers, and hyphens (1-63 chars, cannot start/end with hyphen).${CLR_RESET}"
        done

        read -e -p "Enter domain suffix: " -i "${DOMAIN_SUFFIX:-local}" DOMAIN_SUFFIX

        while true; do
            read -e -p "Enter your timezone : " -i "${TIMEZONE:-Europe/Kyiv}" TIMEZONE
            if validate_timezone "$TIMEZONE"; then
                break
            fi
            echo -e "${CLR_RED}Invalid timezone. Use format like: Europe/London, America/New_York, Asia/Tokyo${CLR_RESET}"
        done

        while true; do
            read -e -p "Enter your email address: " -i "${EMAIL:-admin@example.com}" EMAIL
            if validate_email "$EMAIL"; then
                break
            fi
            echo -e "${CLR_RED}Invalid email address format.${CLR_RESET}"
        done

        while true; do
            read -e -p "Enter your private subnet: " -i "${PRIVATE_SUBNET:-10.0.0.0/24}" PRIVATE_SUBNET
            if validate_subnet "$PRIVATE_SUBNET"; then
                break
            fi
            echo -e "${CLR_RED}Invalid subnet. Use CIDR format like: 10.0.0.0/24, 192.168.1.0/24${CLR_RESET}"
        done
    fi

    FQDN="${PVE_HOSTNAME}.${DOMAIN_SUFFIX}"
    echo -e "${CLR_GREEN}FQDN: ${FQDN}${CLR_RESET}"

    # Get the network prefix (first three octets) from PRIVATE_SUBNET
    PRIVATE_CIDR=$(echo "$PRIVATE_SUBNET" | cut -d'/' -f1 | rev | cut -d'.' -f2- | rev)
    PRIVATE_IP="${PRIVATE_CIDR}.1"
    SUBNET_MASK=$(echo "$PRIVATE_SUBNET" | cut -d'/' -f2)
    PRIVATE_IP_CIDR="${PRIVATE_IP}/${SUBNET_MASK}"

    # Password handling
    if [[ "$NON_INTERACTIVE" == true ]]; then
        if [[ -z "$NEW_ROOT_PASSWORD" ]]; then
            echo -e "${CLR_RED}Error: NEW_ROOT_PASSWORD required in non-interactive mode${CLR_RESET}"
            exit 1
        fi
    else
        if [[ -z "$NEW_ROOT_PASSWORD" ]]; then
            NEW_ROOT_PASSWORD=$(read_password "Enter your System New root password: ")
            while [[ -z "$NEW_ROOT_PASSWORD" ]]; do
                echo -e "${CLR_RED}Password cannot be empty!${CLR_RESET}"
                NEW_ROOT_PASSWORD=$(read_password "Enter your System New root password: ")
            done
        fi
    fi

    echo "Private subnet: $PRIVATE_SUBNET"
    echo "First IP in subnet (CIDR): $PRIVATE_IP_CIDR"

    # SSH Public Key (required for hardened SSH config)
    if [[ "$NON_INTERACTIVE" == true ]]; then
        # In non-interactive mode, SSH_PUBLIC_KEY must be set in config
        if [[ -z "$SSH_PUBLIC_KEY" ]]; then
            # Try to get from rescue system
            if [[ -f /root/.ssh/authorized_keys ]]; then
                SSH_PUBLIC_KEY=$(grep -E "^ssh-(rsa|ed25519|ecdsa)" /root/.ssh/authorized_keys 2>/dev/null | head -1)
            fi
        fi
        if [[ -z "$SSH_PUBLIC_KEY" ]]; then
            echo -e "${CLR_RED}Error: SSH_PUBLIC_KEY required in non-interactive mode${CLR_RESET}"
            exit 1
        fi
        echo -e "${CLR_GREEN}✓ SSH key configured${CLR_RESET}"
    else
        echo ""
        echo -e "${CLR_YELLOW}============================================${CLR_RESET}"
        echo -e "${CLR_YELLOW}  SSH Public Key Configuration${CLR_RESET}"
        echo -e "${CLR_YELLOW}============================================${CLR_RESET}"
        echo -e "${CLR_RED}Password authentication will be DISABLED!${CLR_RESET}"
        echo ""

        # Try to get SSH key from Rescue System (Hetzner stores it in authorized_keys)
        if [[ -z "$SSH_PUBLIC_KEY" && -f /root/.ssh/authorized_keys ]]; then
            SSH_PUBLIC_KEY=$(grep -E "^ssh-(rsa|ed25519|ecdsa)" /root/.ssh/authorized_keys 2>/dev/null | head -1)
        fi

        if [[ -n "$SSH_PUBLIC_KEY" ]]; then
            echo -e "${CLR_GREEN}Found SSH public key:${CLR_RESET}"
            echo "${SSH_PUBLIC_KEY:0:50}..."
            echo ""
            read -e -p "Use this key? (y/n): " -i "y" USE_RESCUE_KEY
            if [[ ! "$USE_RESCUE_KEY" =~ ^[Yy]$ ]]; then
                SSH_PUBLIC_KEY=""
            fi
        fi

        if [[ -z "$SSH_PUBLIC_KEY" ]]; then
            echo "Paste your SSH public key (usually from ~/.ssh/id_rsa.pub or ~/.ssh/id_ed25519.pub):"
            echo "Example: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... user@hostname"
            echo ""
            read -e -p "SSH Public Key: " SSH_PUBLIC_KEY

            while [[ -z "$SSH_PUBLIC_KEY" ]]; do
                echo -e "${CLR_RED}SSH public key is required for secure access!${CLR_RESET}"
                read -e -p "SSH Public Key: " SSH_PUBLIC_KEY
            done

            if [[ ! "$SSH_PUBLIC_KEY" =~ ^ssh-(rsa|ed25519|ecdsa)[[:space:]] ]]; then
                echo -e "${CLR_YELLOW}Warning: SSH key format may be invalid. Continuing anyway...${CLR_RESET}"
            fi
        fi

        echo -e "${CLR_GREEN}✓ SSH key configured${CLR_RESET}"
    fi

    # Tailscale VPN Configuration (Optional)
    if [[ "$NON_INTERACTIVE" == true ]]; then
        # Use config values, default to no if not set
        INSTALL_TAILSCALE="${INSTALL_TAILSCALE:-no}"
        if [[ "$INSTALL_TAILSCALE" == "yes" ]]; then
            TAILSCALE_SSH="${TAILSCALE_SSH:-yes}"
            TAILSCALE_WEBUI="${TAILSCALE_WEBUI:-yes}"
            echo -e "${CLR_GREEN}✓ Tailscale will be installed${CLR_RESET}"
        fi
    else
        echo ""
        echo -e "${CLR_YELLOW}============================================${CLR_RESET}"
        echo -e "${CLR_YELLOW}  Tailscale VPN Configuration (Optional)${CLR_RESET}"
        echo -e "${CLR_YELLOW}============================================${CLR_RESET}"
        echo "Tailscale provides secure remote access to your Proxmox server."
        echo "You can get an auth key from: https://login.tailscale.com/admin/settings/keys"
        echo ""
        read -e -p "Install Tailscale? (y/n): " -i "${INSTALL_TAILSCALE:-y}" INSTALL_TAILSCALE

        if [[ "$INSTALL_TAILSCALE" =~ ^[Yy]$ ]]; then
            INSTALL_TAILSCALE="yes"
            echo ""
            echo "Auth key is optional. If not provided, you'll need to authenticate manually after installation."
            echo "For unattended setup, use a reusable auth key (recommended: with tag and expiry)."
            echo ""
            read -e -p "Tailscale Auth Key (leave empty for manual auth): " -i "${TAILSCALE_AUTH_KEY:-}" TAILSCALE_AUTH_KEY

            if [[ -n "$TAILSCALE_AUTH_KEY" ]]; then
                echo -e "${CLR_GREEN}✓ Auth key provided. Tailscale will be configured automatically${CLR_RESET}"
            else
                echo -e "${CLR_YELLOW}No auth key provided. You'll need to run 'tailscale up --ssh' manually after reboot.${CLR_RESET}"
            fi

            TAILSCALE_SSH="yes"
            TAILSCALE_WEBUI="yes"
            echo -e "${CLR_GREEN}Tailscale SSH and Web UI will be enabled.${CLR_RESET}"
            echo -e "${CLR_GREEN}Proxmox Web UI will be accessible at https://HOSTNAME.your-tailnet.ts.net${CLR_RESET}"
        else
            INSTALL_TAILSCALE="no"
            TAILSCALE_AUTH_KEY=""
            TAILSCALE_SSH="no"
            TAILSCALE_WEBUI="no"
            echo -e "${CLR_YELLOW}Tailscale installation skipped.${CLR_RESET}"
        fi
    fi

    # Save config if requested
    if [[ -n "$SAVE_CONFIG" ]]; then
        save_config "$SAVE_CONFIG"
    fi
}
