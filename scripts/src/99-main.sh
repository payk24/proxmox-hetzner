# =============================================================================
# Finish and reboot
# =============================================================================

# Function to reboot into the main OS
reboot_to_main_os() {
    local end_time=$(date +%s)
    local total_seconds=$((end_time - INSTALL_START_TIME))
    local duration=$(format_duration $total_seconds)

    echo ""
    echo -e "${CLR_CYAN}"
    cat << 'COMPLETE'
  ___           _        _ _       _   _               ____                      _      _
 |_ _|_ __  ___| |_ __ _| | | __ _| |_(_) ___  _ __   / ___|___  _ __ ___  _ __ | | ___| |_ ___
  | || '_ \/ __| __/ _` | | |/ _` | __| |/ _ \| '_ \ | |   / _ \| '_ ` _ \| '_ \| |/ _ \ __/ _ \
  | || | | \__ \ || (_| | | | (_| | |_| | (_) | | | || |__| (_) | | | | | | |_) | |  __/ ||  __/
 |___|_| |_|___/\__\__,_|_|_|\__,_|\__|_|\___/|_| |_| \____\___/|_| |_| |_| .__/|_|\___|\__\___|
                                                                          |_|
COMPLETE
    echo -e "${CLR_RESET}"
    print_success "Total installation time: ${duration}"
    echo ""

    # Build summary content
    local summary=""
    summary+="Security:\n"
    summary+="  ${CLR_GREEN}✓${CLR_RESET} SSH key deployed, password auth disabled\n"
    summary+="  ${CLR_GREEN}✓${CLR_RESET} CPU governor: performance\n"
    summary+="  ${CLR_GREEN}✓${CLR_RESET} Kernel optimized for virtualization\n"
    summary+="\n"
    summary+="Installed:\n"
    summary+="  ${CLR_GREEN}✓${CLR_RESET} btop, iotop, ncdu, tmux, pigz, jq, bat\n"
    summary+="  ${CLR_GREEN}✓${CLR_RESET} libguestfs-tools, smartmontools\n"
    summary+="  ${CLR_GREEN}✓${CLR_RESET} ZSH with autosuggestions\n"
    if [[ "$INSTALL_TAILSCALE" == "yes" ]]; then
        if [[ -n "$TAILSCALE_AUTH_KEY" && "$TAILSCALE_IP" != "pending" && "$TAILSCALE_IP" != "not authenticated" ]]; then
            summary+="  ${CLR_GREEN}✓${CLR_RESET} Tailscale (${TAILSCALE_IP})\n"
        else
            summary+="  ${CLR_YELLOW}⚠${CLR_RESET} Tailscale (needs: tailscale up --ssh)\n"
        fi
    fi
    summary+="\n"
    summary+="Access:\n"
    summary+="  Web UI:  https://${MAIN_IPV4_CIDR%/*}:8006\n"
    summary+="  SSH:     ssh root@${MAIN_IPV4_CIDR%/*}"
    if [[ "$INSTALL_TAILSCALE" == "yes" && -n "$TAILSCALE_AUTH_KEY" && "$TAILSCALE_IP" != "pending" && "$TAILSCALE_IP" != "not authenticated" ]]; then
        summary+="\n  TS SSH:  ssh root@${TAILSCALE_IP}"
        if [[ -n "$TAILSCALE_HOSTNAME" ]]; then
            summary+="\n  TS Web:  https://${TAILSCALE_HOSTNAME}"
        else
            summary+="\n  TS Web:  https://${TAILSCALE_IP}:8006"
        fi
    fi

    echo -e "$summary"
    echo ""

    # Ask user to reboot the system
    read -e -p "Reboot now? (y/n): " -i "y" REBOOT
    if [[ "$REBOOT" == "y" ]]; then
        print_info "Rebooting..."
        reboot
    else
        print_info "Exiting without reboot"
        exit 0
    fi
}

# =============================================================================
# Main execution flow
# =============================================================================

# Collect system info and display status
collect_system_info
show_system_status
get_system_inputs
prepare_packages
download_proxmox_iso
make_answer_toml
make_autoinstall_iso
install_proxmox

# Boot and configure via SSH
boot_proxmox_with_port_forwarding || {
    print_error "Failed to boot Proxmox with port forwarding. Exiting."
    exit 1
}

# Configure Proxmox via SSH
configure_proxmox_via_ssh

# Reboot to the main OS
reboot_to_main_os
