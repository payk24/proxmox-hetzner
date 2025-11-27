# =============================================================================
# Finish and reboot
# =============================================================================

# Calculate and display total installation time
show_total_time() {
    local end_time=$(date +%s)
    local total_seconds=$((end_time - INSTALL_START_TIME))
    local hours=$((total_seconds / 3600))
    local minutes=$(((total_seconds % 3600) / 60))
    local seconds=$((total_seconds % 60))

    if [[ $hours -gt 0 ]]; then
        echo -e "${CLR_GREEN}Total installation time: ${hours}h ${minutes}m ${seconds}s${CLR_RESET}"
    else
        echo -e "${CLR_GREEN}Total installation time: ${minutes}m ${seconds}s${CLR_RESET}"
    fi
}

# Function to reboot into the main OS
reboot_to_main_os() {
    echo -e "${CLR_GREEN}============================================${CLR_RESET}"
    echo -e "${CLR_GREEN}  Installation Complete!${CLR_RESET}"
    echo -e "${CLR_GREEN}============================================${CLR_RESET}"
    show_total_time
    echo ""
    echo -e "${CLR_YELLOW}Security Configuration Summary:${CLR_RESET}"
    echo "  ✓ SSH public key deployed"
    echo "  ✓ Password authentication DISABLED"
    echo "  ✓ CPU governor set to performance"
    echo "  ✓ Kernel parameters optimized for virtualization"
    echo "  ✓ Subscription notice removed"
    echo ""
    echo -e "${CLR_YELLOW}Post-Installation Optimizations:${CLR_RESET}"
    echo "  ✓ Monitoring utilities: btop, iotop, ncdu, tmux, pigz, smartmontools, jq, bat"
    echo "  ✓ VM image tools: libguestfs-tools"
    echo "  ✓ ZFS ARC memory limits configured"
    echo "  ✓ nf_conntrack optimized for high connection counts"
    if [[ "$INSTALL_TAILSCALE" == "yes" ]]; then
        echo "  ✓ Tailscale VPN installed (SSH + Web UI enabled)"
        if [[ -n "$TAILSCALE_AUTH_KEY" ]]; then
            echo "  ✓ Tailscale authenticated (IP: ${TAILSCALE_IP:-pending})"
        else
            echo "  ⚠ Tailscale needs authentication after reboot:"
            echo "      tailscale up --ssh"
            echo "      tailscale serve --bg --https=443 https://127.0.0.1:8006"
        fi
    fi
    echo ""
    echo -e "${CLR_YELLOW}Access Information:${CLR_RESET}"
    echo "  Web UI:    https://${MAIN_IPV4_CIDR%/*}:8006"
    echo "  SSH:       ssh root@${MAIN_IPV4_CIDR%/*}"
    if [[ "$INSTALL_TAILSCALE" == "yes" && -n "$TAILSCALE_AUTH_KEY" && "$TAILSCALE_IP" != "pending" && "$TAILSCALE_IP" != "not authenticated" ]]; then
        echo "  Tailscale SSH: ssh root@${TAILSCALE_IP}"
        if [[ -n "$TAILSCALE_HOSTNAME" ]]; then
            echo "  Tailscale Web UI: https://${TAILSCALE_HOSTNAME}"
        else
            echo "  Tailscale Web UI: https://${TAILSCALE_IP}:8006"
        fi
    fi
    echo ""

    #ask user to reboot the system
    read -e -p "Do you want to reboot the system? (y/n): " -i "y" REBOOT
    if [[ "$REBOOT" == "y" ]]; then
        echo -e "${CLR_YELLOW}Rebooting the system...${CLR_RESET}"
        reboot
    else
        echo -e "${CLR_YELLOW}Exiting...${CLR_RESET}"
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
    echo -e "${CLR_RED}Failed to boot Proxmox with port forwarding. Exiting.${CLR_RESET}"
    exit 1
}

# Configure Proxmox via SSH
configure_proxmox_via_ssh

# Reboot to the main OS
reboot_to_main_os
