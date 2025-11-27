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
        PRIVATE_SUBNET="${PRIVATE_SUBNET:-10.0.0.0/24}"
    else
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

        local tz_prompt="Enter your timezone: "
        while true; do
            read -e -p "$tz_prompt" -i "${TIMEZONE:-Europe/Kyiv}" TIMEZONE
            if validate_timezone "$TIMEZONE"; then
                printf "\033[A\r${CLR_GREEN}✓${CLR_RESET} ${tz_prompt}${TIMEZONE}\033[K\n"
                break
            fi
            echo -e "${CLR_RED}Invalid timezone. Use format like: Europe/London, America/New_York, Asia/Tokyo${CLR_RESET}"
        done

        local email_prompt="Enter your email address: "
        while true; do
            read -e -p "$email_prompt" -i "${EMAIL:-admin@example.com}" EMAIL
            if validate_email "$EMAIL"; then
                printf "\033[A\r${CLR_GREEN}✓${CLR_RESET} ${email_prompt}${EMAIL}\033[K\n"
                break
            fi
            echo -e "${CLR_RED}Invalid email address format.${CLR_RESET}"
        done

        local subnet_prompt="Enter your private subnet: "
        while true; do
            read -e -p "$subnet_prompt" -i "${PRIVATE_SUBNET:-10.0.0.0/24}" PRIVATE_SUBNET
            if validate_subnet "$PRIVATE_SUBNET"; then
                printf "\033[A\r${CLR_GREEN}✓${CLR_RESET} ${subnet_prompt}${PRIVATE_SUBNET}\033[K\n"
                break
            fi
            echo -e "${CLR_RED}Invalid subnet. Use CIDR format like: 10.0.0.0/24, 192.168.1.0/24${CLR_RESET}"
        done

        # ZFS RAID mode selection (only if 2+ drives detected)
        if [ "${NVME_COUNT:-0}" -ge 2 ]; then
            # Interactive radio-button style ZFS mode selector
            local options=("raid1" "raid0" "single")
            local labels=("RAID-1 (mirror) - Recommended" "RAID-0 (stripe) - No redundancy" "Single drive - No redundancy")
            local descriptions=("Survives 1 disk failure" "2x space & speed, data loss if any disk fails" "Uses first drive only, ignores other drives")
            local selected=0
            local key=""
            local box_lines=0

            # Hide cursor
            tput civis

            # Function to draw the selection box using boxes
            draw_zfs_menu() {
                local content=""
                for i in "${!options[@]}"; do
                    if [ $i -eq $selected ]; then
                        content+="[*]|${labels[$i]}"$'\n'
                        content+="|  └─ ${descriptions[$i]}"$'\n'
                    else
                        content+="[ ]|${labels[$i]}"$'\n'
                        content+="|  └─ ${descriptions[$i]}"$'\n'
                    fi
                done
                # Remove trailing newline
                content="${content%$'\n'}"

                {
                    echo "ZFS Storage Mode (↑/↓ select, Enter confirm)"
                    echo "$content" | column -t -s '|'
                } | boxes -d stone -p a1
            }

            # Count lines in the box for clearing later
            box_lines=$(draw_zfs_menu | wc -l)

            # Save cursor position
            tput sc

            while true; do
                # Move cursor to saved position
                tput rc

                # Draw the menu with colors (use $'...' for literal escape codes to avoid sed backreference issues)
                draw_zfs_menu | sed -e $'s/\\[\\*\\]/\033[1;32m[●]\033[m/g' \
                                    -e $'s/\\[ \\]/\033[1;34m[○]\033[m/g'

                # Read a single keypress
                IFS= read -rsn1 key

                # Check for escape sequence (arrow keys)
                if [[ "$key" == $'\x1b' ]]; then
                    read -rsn2 -t 0.1 key || true  # ignore timeout exit code with set -e
                    case "$key" in
                        '[A') # Up arrow
                            ((selected--)) || true  # prevent exit when result is 0
                            [ $selected -lt 0 ] && selected=$((${#options[@]} - 1))
                            ;;
                        '[B') # Down arrow
                            ((selected++)) || true  # prevent exit when result is 0
                            [ $selected -ge ${#options[@]} ] && selected=0
                            ;;
                    esac
                elif [[ "$key" == "" ]]; then
                    # Enter pressed - confirm selection
                    break
                elif [[ "$key" == "1" ]]; then
                    selected=0; break
                elif [[ "$key" == "2" ]]; then
                    selected=1; break
                elif [[ "$key" == "3" ]]; then
                    selected=2; break
                fi
            done

            # Show cursor again
            tput cnorm

            # Set the selected ZFS RAID mode
            ZFS_RAID="${options[$selected]}"

            # Clear the selection box completely
            tput rc
            for ((i=0; i<box_lines; i++)); do
                printf "\033[K\n"
            done
            tput rc

            # Show confirmation
            echo -e "${CLR_GREEN}✓${CLR_RESET} ZFS mode: ${labels[$selected]}"
        fi
    fi

    FQDN="${PVE_HOSTNAME}.${DOMAIN_SUFFIX}"

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
            local password_prompt="Enter your System New root password: "
            NEW_ROOT_PASSWORD=$(read_password "$password_prompt")
            while [[ -z "$NEW_ROOT_PASSWORD" ]]; do
                echo -e "${CLR_RED}Password cannot be empty!${CLR_RESET}"
                NEW_ROOT_PASSWORD=$(read_password "$password_prompt")
            done
            echo -e "${CLR_GREEN}✓${CLR_RESET} ${password_prompt}********"
        fi
    fi

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
        parse_ssh_key "$SSH_PUBLIC_KEY"
        echo -e "${CLR_GREEN}✓ SSH key configured (${SSH_KEY_TYPE})${CLR_RESET}"
    else
        # Try to get SSH key from Rescue System (Hetzner stores it in authorized_keys)
        local DETECTED_SSH_KEY=""
        if [[ -f /root/.ssh/authorized_keys ]]; then
            DETECTED_SSH_KEY=$(grep -E "^ssh-(rsa|ed25519|ecdsa)" /root/.ssh/authorized_keys 2>/dev/null | head -1)
        fi

        if [[ -n "$DETECTED_SSH_KEY" ]]; then
            # Key detected - show interactive selector
            parse_ssh_key "$DETECTED_SSH_KEY"

            local options=("detected" "manual")
            local labels=("Use detected key" "Enter different key")
            local descriptions=("Recommended - already configured in Hetzner" "Paste your own SSH public key")
            local selected=0
            local key=""
            local box_lines=0

            # Hide cursor
            tput civis

            # Function to draw the SSH selection box
            draw_ssh_menu() {
                local content=""
                content+="! Password authentication will be DISABLED"$'\n'
                content+=""$'\n'
                content+="Detected key from Rescue System:"$'\n'
                content+="  Type:    ${SSH_KEY_TYPE}"$'\n'
                content+="  Key:     ${SSH_KEY_SHORT}"$'\n'
                if [[ -n "$SSH_KEY_COMMENT" ]]; then
                    content+="  Comment: ${SSH_KEY_COMMENT}"$'\n'
                fi
                content+=""$'\n'
                for i in "${!options[@]}"; do
                    if [ $i -eq $selected ]; then
                        content+="[*]|${labels[$i]}"$'\n'
                        content+="|  ^-- ${descriptions[$i]}"$'\n'
                    else
                        content+="[ ]|${labels[$i]}"$'\n'
                        content+="|  ^-- ${descriptions[$i]}"$'\n'
                    fi
                done
                # Remove trailing newline
                content="${content%$'\n'}"

                {
                    echo "SSH Public Key (^/v select, Enter confirm)"
                    echo "$content" | column -t -s '|'
                } | boxes -d stone -p a1
            }

            # Count lines in the box for clearing later
            box_lines=$(draw_ssh_menu | wc -l)

            # Save cursor position
            tput sc

            while true; do
                # Move cursor to saved position
                tput rc

                # Draw the menu with colors
                draw_ssh_menu | sed -e $'s/\\[\\*\\]/\033[1;32m[*]\033[m/g' \
                                    -e $'s/\\[ \\]/\033[1;34m[ ]\033[m/g' \
                                    -e $'s/^\\(.*!.*\\)$/\033[1;33m\\1\033[m/g'

                # Read a single keypress
                IFS= read -rsn1 key

                # Check for escape sequence (arrow keys)
                if [[ "$key" == $'\x1b' ]]; then
                    read -rsn2 -t 0.1 key || true
                    case "$key" in
                        '[A') # Up arrow
                            ((selected--)) || true
                            [ $selected -lt 0 ] && selected=$((${#options[@]} - 1))
                            ;;
                        '[B') # Down arrow
                            ((selected++)) || true
                            [ $selected -ge ${#options[@]} ] && selected=0
                            ;;
                    esac
                elif [[ "$key" == "" ]]; then
                    # Enter pressed - confirm selection
                    break
                elif [[ "$key" == "1" ]]; then
                    selected=0; break
                elif [[ "$key" == "2" ]]; then
                    selected=1; break
                fi
            done

            # Show cursor again
            tput cnorm

            # Clear the selection box
            tput rc
            for ((i=0; i<box_lines; i++)); do
                printf "\033[K\n"
            done
            tput rc

            if [[ "${options[$selected]}" == "detected" ]]; then
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
            local input_box_lines=0

            draw_ssh_input_box() {
                local content=""
                content+="! Password authentication will be DISABLED"$'\n'
                content+=""$'\n'
                if [[ -z "$DETECTED_SSH_KEY" ]]; then
                    content+="No SSH key detected in Rescue System."$'\n'
                fi
                content+=""$'\n'
                content+="Paste your SSH public key below:"$'\n'
                content+="(Usually from ~/.ssh/id_ed25519.pub or ~/.ssh/id_rsa.pub)"

                {
                    echo "SSH Public Key Configuration"
                    echo "$content"
                } | boxes -d stone -p a1
            }

            # Display the input box
            input_box_lines=$(draw_ssh_input_box | wc -l)
            tput sc
            draw_ssh_input_box | sed -e $'s/^\\(.*!.*\\)$/\033[1;33m\\1\033[m/g'

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

            # Clear the input box and show confirmation
            tput rc
            for ((i=0; i<input_box_lines+3; i++)); do
                printf "\033[K\n"
            done
            tput rc

            parse_ssh_key "$SSH_PUBLIC_KEY"
            echo -e "${CLR_GREEN}✓${CLR_RESET} SSH key configured (${SSH_KEY_TYPE})"
        fi
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
        # Interactive Tailscale configuration
        local options=("yes" "no")
        local labels=("Install Tailscale" "Skip installation")
        local descriptions=("Recommended for secure remote access" "Install Tailscale later if needed")
        local selected=0
        local key=""
        local box_lines=0

        # Hide cursor
        tput civis

        # Function to draw the Tailscale selection box
        draw_tailscale_menu() {
            local content=""
            content+="Tailscale provides secure remote access to your server."$'\n'
            content+="Auth key: https://login.tailscale.com/admin/settings/keys"$'\n'
            content+=""$'\n'
            for i in "${!options[@]}"; do
                if [ $i -eq $selected ]; then
                    content+="[*]|${labels[$i]}"$'\n'
                    content+="|  ^-- ${descriptions[$i]}"$'\n'
                else
                    content+="[ ]|${labels[$i]}"$'\n'
                    content+="|  ^-- ${descriptions[$i]}"$'\n'
                fi
            done
            # Remove trailing newline
            content="${content%$'\n'}"

            {
                echo "Tailscale VPN - Optional (^/v select, Enter confirm)"
                echo "$content" | column -t -s '|'
            } | boxes -d stone -p a1
        }

        # Count lines in the box for clearing later
        box_lines=$(draw_tailscale_menu | wc -l)

        # Save cursor position
        tput sc

        while true; do
            # Move cursor to saved position
            tput rc

            # Draw the menu with colors
            draw_tailscale_menu | sed -e $'s/\\[\\*\\]/\033[1;32m[*]\033[m/g' \
                                      -e $'s/\\[ \\]/\033[1;34m[ ]\033[m/g'

            # Read a single keypress
            IFS= read -rsn1 key

            # Check for escape sequence (arrow keys)
            if [[ "$key" == $'\x1b' ]]; then
                read -rsn2 -t 0.1 key || true
                case "$key" in
                    '[A') # Up arrow
                        ((selected--)) || true
                        [ $selected -lt 0 ] && selected=$((${#options[@]} - 1))
                        ;;
                    '[B') # Down arrow
                        ((selected++)) || true
                        [ $selected -ge ${#options[@]} ] && selected=0
                        ;;
                esac
            elif [[ "$key" == "" ]]; then
                # Enter pressed - confirm selection
                break
            elif [[ "$key" == "1" ]]; then
                selected=0; break
            elif [[ "$key" == "2" ]]; then
                selected=1; break
            fi
        done

        # Show cursor again
        tput cnorm

        # Clear the selection box
        tput rc
        for ((i=0; i<box_lines; i++)); do
            printf "\033[K\n"
        done
        tput rc

        if [[ "${options[$selected]}" == "yes" ]]; then
            INSTALL_TAILSCALE="yes"
            TAILSCALE_SSH="yes"
            TAILSCALE_WEBUI="yes"

            # Show auth key input box
            local auth_box_lines=0

            draw_auth_key_box() {
                local content=""
                content+="Auth key enables automatic configuration."$'\n'
                content+="Leave empty for manual auth after reboot."$'\n'
                content+=""$'\n'
                content+="For unattended setup, use a reusable auth key"$'\n'
                content+="with tags and expiry for better security."

                {
                    echo "Tailscale Auth Key (optional)"
                    echo "$content"
                } | boxes -d stone -p a1
            }

            # Display the auth key input box
            auth_box_lines=$(draw_auth_key_box | wc -l)
            tput sc
            draw_auth_key_box

            # Prompt for auth key
            read -e -p "Auth Key: " -i "${TAILSCALE_AUTH_KEY:-}" TAILSCALE_AUTH_KEY

            # Clear the input box
            tput rc
            for ((i=0; i<auth_box_lines+2; i++)); do
                printf "\033[K\n"
            done
            tput rc

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

    # Save config if requested
    if [[ -n "$SAVE_CONFIG" ]]; then
        save_config "$SAVE_CONFIG"
    fi
}
