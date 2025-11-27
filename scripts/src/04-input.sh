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
        local iface_prompt="Interface name (options: ${AVAILABLE_ALTNAMES}): "
        read -e -p "$iface_prompt" -i "$INTERFACE_NAME" INTERFACE_NAME
        # Move cursor up one line and overwrite with checkmark
        printf "\033[A\r${CLR_GREEN}✓${CLR_RESET} ${iface_prompt}${INTERFACE_NAME}\033[K\n"
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

    # Get user input for other configuration with validation
    # Note: PVE_HOSTNAME is used instead of HOSTNAME to avoid conflict with bash built-in
    if [[ "$NON_INTERACTIVE" == true ]]; then
        # Use defaults or config values in non-interactive mode
        PVE_HOSTNAME="${PVE_HOSTNAME:-pve}"
        DOMAIN_SUFFIX="${DOMAIN_SUFFIX:-local}"
        TIMEZONE="${TIMEZONE:-Europe/Kyiv}"
        EMAIL="${EMAIL:-admin@example.com}"
        BRIDGE_MODE="${BRIDGE_MODE:-internal}"
        PRIVATE_SUBNET="${PRIVATE_SUBNET:-10.0.0.0/24}"

        # Password handling in non-interactive mode
        if [[ -z "$NEW_ROOT_PASSWORD" ]]; then
            echo -e "${CLR_RED}Error: NEW_ROOT_PASSWORD required in non-interactive mode${CLR_RESET}"
            exit 1
        fi

        # SSH Public Key in non-interactive mode
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
        parse_ssh_key "$SSH_PUBLIC_KEY"
        echo -e "${CLR_GREEN}✓ SSH key configured (${SSH_KEY_TYPE})${CLR_RESET}"

        # Tailscale in non-interactive mode
        INSTALL_TAILSCALE="${INSTALL_TAILSCALE:-no}"
        if [[ "$INSTALL_TAILSCALE" == "yes" ]]; then
            TAILSCALE_SSH="${TAILSCALE_SSH:-yes}"
            TAILSCALE_WEBUI="${TAILSCALE_WEBUI:-yes}"
            echo -e "${CLR_GREEN}✓ Tailscale will be installed${CLR_RESET}"
        fi
    else
        # =====================================================================
        # SECTION 1: Text inputs (hostname, domain, email, password)
        # =====================================================================

        local hostname_prompt="Enter your hostname (e.g., pve, proxmox): "
        while true; do
            read -e -p "$hostname_prompt" -i "${PVE_HOSTNAME:-pve}" PVE_HOSTNAME
            if validate_hostname "$PVE_HOSTNAME"; then
                printf "\033[A\r${CLR_GREEN}✓${CLR_RESET} ${hostname_prompt}${PVE_HOSTNAME}\033[K\n"
                break
            fi
            echo -e "${CLR_RED}Invalid hostname. Use only letters, numbers, and hyphens (1-63 chars, cannot start/end with hyphen).${CLR_RESET}"
        done

        local domain_prompt="Enter domain suffix: "
        read -e -p "$domain_prompt" -i "${DOMAIN_SUFFIX:-local}" DOMAIN_SUFFIX
        printf "\033[A\r${CLR_GREEN}✓${CLR_RESET} ${domain_prompt}${DOMAIN_SUFFIX}\033[K\n"

        local email_prompt="Enter your email address: "
        while true; do
            read -e -p "$email_prompt" -i "${EMAIL:-admin@example.com}" EMAIL
            if validate_email "$EMAIL"; then
                printf "\033[A\r${CLR_GREEN}✓${CLR_RESET} ${email_prompt}${EMAIL}\033[K\n"
                break
            fi
            echo -e "${CLR_RED}Invalid email address format.${CLR_RESET}"
        done

        if [[ -z "$NEW_ROOT_PASSWORD" ]]; then
            local password_prompt="Enter new root password: "
            NEW_ROOT_PASSWORD=$(read_password "$password_prompt")
            while [[ -z "$NEW_ROOT_PASSWORD" ]]; do
                echo -e "${CLR_RED}Password cannot be empty!${CLR_RESET}"
                NEW_ROOT_PASSWORD=$(read_password "$password_prompt")
            done
            echo -e "${CLR_GREEN}✓${CLR_RESET} ${password_prompt}********"
        fi

        # =====================================================================
        # SECTION 2: Interactive menus (all selection menus grouped together)
        # =====================================================================
        echo ""  # Visual separator before menus

        # --- Timezone selection menu ---
        local tz_options=("Europe/Kyiv" "Europe/London" "Europe/Berlin" "America/New_York" "America/Los_Angeles" "Asia/Tokyo" "UTC" "custom")
        local tz_default="${TIMEZONE:-Europe/Kyiv}"

        interactive_menu \
            "Timezone (↑/↓ select, Enter confirm)" \
            "" \
            "Europe/Kyiv|Ukraine" \
            "Europe/London|United Kingdom (GMT/BST)" \
            "Europe/Berlin|Germany, Central Europe (CET/CEST)" \
            "America/New_York|US Eastern Time (EST/EDT)" \
            "America/Los_Angeles|US Pacific Time (PST/PDT)" \
            "Asia/Tokyo|Japan Standard Time (JST)" \
            "UTC|Coordinated Universal Time" \
            "Custom|Enter timezone manually"

        if [[ $MENU_SELECTED -eq 7 ]]; then
            # Custom timezone - prompt for manual entry
            local tz_prompt="Enter your timezone: "
            while true; do
                read -e -p "$tz_prompt" -i "$tz_default" TIMEZONE
                if validate_timezone "$TIMEZONE"; then
                    printf "\033[A\r${CLR_GREEN}✓${CLR_RESET} Timezone: ${TIMEZONE}\033[K\n"
                    break
                fi
                echo -e "${CLR_RED}Invalid timezone. Use format like: Europe/London, America/New_York${CLR_RESET}"
            done
        else
            TIMEZONE="${tz_options[$MENU_SELECTED]}"
            echo -e "${CLR_GREEN}✓${CLR_RESET} Timezone: ${TIMEZONE}"
        fi

        # --- Network bridge mode selection menu ---
        local bridge_options=("internal" "external" "both")
        local bridge_header="Configure network bridges for VMs and containers"$'\n'
        bridge_header+="vmbr0 = external (bridged to physical NIC)"$'\n'
        bridge_header+="vmbr1 = internal (NAT with private subnet)"

        interactive_menu \
            "Network Bridge Mode (↑/↓ select, Enter confirm)" \
            "$bridge_header" \
            "Internal only (NAT)|VMs use private IPs with NAT to internet" \
            "External only (Bridged)|VMs get IPs from your router/DHCP" \
            "Both bridges|Internal NAT + External bridged network"

        BRIDGE_MODE="${bridge_options[$MENU_SELECTED]}"
        case "$BRIDGE_MODE" in
            internal)
                echo -e "${CLR_GREEN}✓${CLR_RESET} Bridge mode: Internal NAT only (vmbr0)"
                ;;
            external)
                echo -e "${CLR_GREEN}✓${CLR_RESET} Bridge mode: External bridged only (vmbr0)"
                ;;
            both)
                echo -e "${CLR_GREEN}✓${CLR_RESET} Bridge mode: Both (vmbr0=external, vmbr1=internal)"
                ;;
        esac

        # --- Private subnet selection menu (only if internal bridge is used) ---
        if [[ "$BRIDGE_MODE" == "internal" || "$BRIDGE_MODE" == "both" ]]; then
            local subnet_options=("10.0.0.0/24" "192.168.1.0/24" "172.16.0.0/24" "custom")
            local subnet_default="${PRIVATE_SUBNET:-10.0.0.0/24}"

            interactive_menu \
                "Private Subnet (↑/↓ select, Enter confirm)" \
                "Internal network for VMs and containers" \
                "10.0.0.0/24|Class A private (recommended)" \
                "192.168.1.0/24|Class C private (common home network)" \
                "172.16.0.0/24|Class B private" \
                "Custom|Enter subnet manually"

            if [[ $MENU_SELECTED -eq 3 ]]; then
                # Custom subnet - prompt for manual entry
                local subnet_prompt="Enter your private subnet: "
                while true; do
                    read -e -p "$subnet_prompt" -i "$subnet_default" PRIVATE_SUBNET
                    if validate_subnet "$PRIVATE_SUBNET"; then
                        printf "\033[A\r${CLR_GREEN}✓${CLR_RESET} Private subnet: ${PRIVATE_SUBNET}\033[K\n"
                        break
                    fi
                    echo -e "${CLR_RED}Invalid subnet. Use CIDR format like: 10.0.0.0/24, 192.168.1.0/24${CLR_RESET}"
                done
            else
                PRIVATE_SUBNET="${subnet_options[$MENU_SELECTED]}"
                echo -e "${CLR_GREEN}✓${CLR_RESET} Private subnet: ${PRIVATE_SUBNET}"
            fi
        fi

        # --- ZFS RAID mode selection menu (only if 2+ drives detected) ---
        if [ "${NVME_COUNT:-0}" -ge 2 ]; then
            local zfs_options=("raid1" "raid0" "single")
            local zfs_labels=("RAID-1 (mirror) - Recommended" "RAID-0 (stripe) - No redundancy" "Single drive - No redundancy")

            interactive_menu \
                "ZFS Storage Mode (↑/↓ select, Enter confirm)" \
                "" \
                "${zfs_labels[0]}|Survives 1 disk failure" \
                "${zfs_labels[1]}|2x space & speed, data loss if any disk fails" \
                "${zfs_labels[2]}|Uses first drive only, ignores other drives"

            ZFS_RAID="${zfs_options[$MENU_SELECTED]}"
            echo -e "${CLR_GREEN}✓${CLR_RESET} ZFS mode: ${zfs_labels[$MENU_SELECTED]}"
        fi

        # --- SSH Public Key selection menu ---
        # Try to get SSH key from Rescue System (Hetzner stores it in authorized_keys)
        local DETECTED_SSH_KEY=""
        if [[ -f /root/.ssh/authorized_keys ]]; then
            DETECTED_SSH_KEY=$(grep -E "^ssh-(rsa|ed25519|ecdsa)" /root/.ssh/authorized_keys 2>/dev/null | head -1)
        fi

        if [[ -n "$DETECTED_SSH_KEY" ]]; then
            # Key detected - show interactive selector
            parse_ssh_key "$DETECTED_SSH_KEY"

            # Build header with key info
            local ssh_header="! Password authentication will be DISABLED"$'\n'
            ssh_header+="Detected key from Rescue System:"$'\n'
            ssh_header+="  Type:    ${SSH_KEY_TYPE}"$'\n'
            ssh_header+="  Key:     ${SSH_KEY_SHORT}"
            if [[ -n "$SSH_KEY_COMMENT" ]]; then
                ssh_header+=$'\n'"  Comment: ${SSH_KEY_COMMENT}"
            fi

            interactive_menu \
                "SSH Public Key (↑/↓ select, Enter confirm)" \
                "$ssh_header" \
                "Use detected key|Recommended - already configured in Hetzner" \
                "Enter different key|Paste your own SSH public key"

            if [[ $MENU_SELECTED -eq 0 ]]; then
                SSH_PUBLIC_KEY="$DETECTED_SSH_KEY"
                echo -e "${CLR_GREEN}✓${CLR_RESET} SSH key configured (${SSH_KEY_TYPE})"
            else
                # User wants to enter a different key
                SSH_PUBLIC_KEY=""
            fi
        fi

        # If no key yet (either not detected or user chose to enter manually)
        if [[ -z "$SSH_PUBLIC_KEY" ]]; then
            # Show input box for manual entry
            local ssh_input_content="! Password authentication will be DISABLED"$'\n'
            if [[ -z "$DETECTED_SSH_KEY" ]]; then
                ssh_input_content+=$'\n'"No SSH key detected in Rescue System."
            fi
            ssh_input_content+=$'\n'$'\n'"Paste your SSH public key below:"$'\n'
            ssh_input_content+="(Usually from ~/.ssh/id_ed25519.pub or ~/.ssh/id_rsa.pub)"

            local input_box_lines
            input_box_lines=$({
                echo "SSH Public Key Configuration"
                echo "$ssh_input_content"
            } | boxes -d stone -p a1 -s $MENU_BOX_WIDTH | wc -l)

            {
                echo "SSH Public Key Configuration"
                echo "$ssh_input_content"
            } | boxes -d stone -p a1 -s $MENU_BOX_WIDTH

            # Prompt for key
            local ssh_prompt="SSH Public Key: "
            while true; do
                read -e -p "$ssh_prompt" SSH_PUBLIC_KEY
                if [[ -n "$SSH_PUBLIC_KEY" ]]; then
                    if validate_ssh_key "$SSH_PUBLIC_KEY"; then
                        break
                    else
                        echo -e "${CLR_YELLOW}Warning: SSH key format may be invalid. Continue anyway? (y/n): ${CLR_RESET}"
                        read -rsn1 confirm
                        echo ""
                        if [[ "$confirm" =~ ^[Yy]$ ]]; then
                            break
                        fi
                    fi
                else
                    echo -e "${CLR_RED}SSH public key is required for secure access!${CLR_RESET}"
                fi
            done

            # Clear the input box and show confirmation (move up and clear)
            tput cuu $((input_box_lines + 3))
            for ((i=0; i<input_box_lines+3; i++)); do
                printf "\033[2K\n"
            done
            tput cuu $((input_box_lines + 3))

            parse_ssh_key "$SSH_PUBLIC_KEY"
            echo -e "${CLR_GREEN}✓${CLR_RESET} SSH key configured (${SSH_KEY_TYPE})"
        fi

        # --- Tailscale VPN selection menu ---
        local ts_header="Tailscale provides secure remote access to your server."$'\n'
        ts_header+="Auth key: https://login.tailscale.com/admin/settings/keys"

        interactive_menu \
            "Tailscale VPN - Optional (↑/↓ select, Enter confirm)" \
            "$ts_header" \
            "Install Tailscale|Recommended for secure remote access" \
            "Skip installation|Install Tailscale later if needed"

        if [[ $MENU_SELECTED -eq 0 ]]; then
            INSTALL_TAILSCALE="yes"
            TAILSCALE_SSH="yes"
            TAILSCALE_WEBUI="yes"

            # Show auth key input box
            local auth_content="Auth key enables automatic configuration."$'\n'
            auth_content+="Leave empty for manual auth after reboot."$'\n'
            auth_content+=$'\n'
            auth_content+="For unattended setup, use a reusable auth key"$'\n'
            auth_content+="with tags and expiry for better security."

            local auth_box_lines
            auth_box_lines=$({
                echo "Tailscale Auth Key (optional)"
                echo "$auth_content"
            } | boxes -d stone -p a1 -s $MENU_BOX_WIDTH | wc -l)

            {
                echo "Tailscale Auth Key (optional)"
                echo "$auth_content"
            } | boxes -d stone -p a1 -s $MENU_BOX_WIDTH

            # Prompt for auth key
            read -e -p "Auth Key: " -i "${TAILSCALE_AUTH_KEY:-}" TAILSCALE_AUTH_KEY

            # Clear the input box (move up and clear)
            tput cuu $((auth_box_lines + 2))
            for ((i=0; i<auth_box_lines+2; i++)); do
                printf "\033[2K\n"
            done
            tput cuu $((auth_box_lines + 2))

            # Show confirmation
            if [[ -n "$TAILSCALE_AUTH_KEY" ]]; then
                echo -e "${CLR_GREEN}✓${CLR_RESET} Tailscale will be installed (auto-connect)"
            else
                echo -e "${CLR_GREEN}✓${CLR_RESET} Tailscale will be installed (manual auth required)"
            fi
        else
            INSTALL_TAILSCALE="no"
            TAILSCALE_AUTH_KEY=""
            TAILSCALE_SSH="no"
            TAILSCALE_WEBUI="no"
            echo -e "${CLR_GREEN}✓${CLR_RESET} Tailscale installation skipped"
        fi
    fi

    # Calculate derived values
    FQDN="${PVE_HOSTNAME}.${DOMAIN_SUFFIX}"

    # Calculate private network values (only if internal bridge is used)
    if [[ "$BRIDGE_MODE" == "internal" || "$BRIDGE_MODE" == "both" ]]; then
        # Get the network prefix (first three octets) from PRIVATE_SUBNET
        PRIVATE_CIDR=$(echo "$PRIVATE_SUBNET" | cut -d'/' -f1 | rev | cut -d'.' -f2- | rev)
        PRIVATE_IP="${PRIVATE_CIDR}.1"
        SUBNET_MASK=$(echo "$PRIVATE_SUBNET" | cut -d'/' -f2)
        PRIVATE_IP_CIDR="${PRIVATE_IP}/${SUBNET_MASK}"
    fi

    # Save config if requested
    if [[ -n "$SAVE_CONFIG" ]]; then
        save_config "$SAVE_CONFIG"
    fi
}
