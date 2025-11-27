# =============================================================================
# Network configuration
# =============================================================================

configure_network() {
    print_info "Starting network configuration..."

    # ==========================================================================
    # nf_conntrack configuration
    # ==========================================================================
    {
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
CONNTRACKEOF
    } > /dev/null 2>&1 &
    show_progress $! "Configuring nf_conntrack"

    # ==========================================================================
    # NTP Synchronization (always enabled)
    # ==========================================================================
    {
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
NTPEOF
    } > /dev/null 2>&1 &
    show_progress $! "Configuring NTP time synchronization"

    # ==========================================================================
    # Tailscale VPN (optional)
    # ==========================================================================
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
    # Basic Firewall (optional, default: no)
    # ==========================================================================
    if [[ "$INSTALL_FIREWALL" == "yes" ]]; then
        {
            remote_copy "template_files/firewall-setup.sh" "/tmp/firewall-setup.sh"
            remote_exec "chmod +x /tmp/firewall-setup.sh && /tmp/firewall-setup.sh && rm /tmp/firewall-setup.sh"
        } > /dev/null 2>&1 &
        show_progress $! "Configuring basic firewall rules"
    fi

    print_success "Network configuration complete"
}
