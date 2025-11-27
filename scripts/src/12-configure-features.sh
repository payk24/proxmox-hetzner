# =============================================================================
# Optional features and finalization
# =============================================================================

configure_optional_features() {
    print_info "Configuring optional features..."

    # ==========================================================================
    # Hide Ceph from UI (optional, default: yes)
    # ==========================================================================
    if [[ "$HIDE_CEPH" == "yes" ]]; then
        {
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
                fi

                # Alternative: patch JavaScript to hide Ceph panel completely
                PVE_MANAGER_JS="/usr/share/pve-manager/js/pvemanagerlib.js"
                if [ -f "$PVE_MANAGER_JS" ]; then
                    if ! grep -q "// Ceph hidden" "$PVE_MANAGER_JS"; then
                        sed -i "s/itemId: 'ceph'/itemId: 'ceph', hidden: true \/\/ Ceph hidden/g" "$PVE_MANAGER_JS" 2>/dev/null || true
                    fi
                fi

                systemctl restart pveproxy.service
CEPHEOF
        } > /dev/null 2>&1 &
        show_progress $! "Hiding Ceph from UI"
    fi

    # ==========================================================================
    # Journald Optimization (optional, default: yes)
    # ==========================================================================
    if [[ "$OPTIMIZE_JOURNALD" == "yes" ]]; then
        {
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
JOURNALDEOF
        } > /dev/null 2>&1 &
        show_progress $! "Optimizing journald log settings"
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
        {
            remote_exec "chmod -x /etc/update-motd.d/* 2>/dev/null || true"
            remote_copy "template_files/00-proxmox-motd" "/etc/update-motd.d/00-proxmox-info"
            remote_exec "chmod +x /etc/update-motd.d/00-proxmox-info"
            remote_exec "sed -i 's/^#*PrintLastLog.*/PrintLastLog no/' /etc/ssh/sshd_config 2>/dev/null || true"
        } > /dev/null 2>&1 &
        show_progress $! "Configuring custom MOTD"
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
    # PCI Passthrough Preparation (optional, default: no)
    # ==========================================================================
    if [[ "$ENABLE_PCI_PASSTHROUGH" == "yes" ]]; then
        {
            remote_exec_script << 'IOMMUEOF'
                # Detect CPU vendor
                if grep -q "GenuineIntel" /proc/cpuinfo; then
                    IOMMU_PARAM="intel_iommu=on"
                elif grep -q "AuthenticAMD" /proc/cpuinfo; then
                    IOMMU_PARAM="amd_iommu=on"
                else
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
IOMMUEOF
        } > /dev/null 2>&1 &
        show_progress $! "Configuring PCI passthrough (IOMMU)"
    fi

    # ==========================================================================
    # Let's Encrypt Certificate (optional, default: no)
    # ==========================================================================
    if [[ "$INSTALL_LETSENCRYPT" == "yes" && -n "$LETSENCRYPT_DOMAIN" ]]; then
        {
            remote_exec_script << LEEOF
                export DEBIAN_FRONTEND=noninteractive

                # Install pve-acme for Proxmox ACME integration
                apt-get install -yqq pve-acme 2>/dev/null || true

                # Register ACME account if not exists
                if ! pvenode acme account list 2>/dev/null | grep -q "default"; then
                    pvenode acme account register default --contact "${EMAIL}" --directory https://acme-v02.api.letsencrypt.org/directory
                fi

                # Configure domain for certificate
                pvenode config set --acme "domains=${LETSENCRYPT_DOMAIN}"

                # Order certificate
                if pvenode acme cert order 2>/dev/null; then
                    # Setup auto-renewal cron
                    if ! grep -q "pvenode acme cert renew" /etc/crontab 2>/dev/null; then
                        echo "0 3 * * * root pvenode acme cert renew --force 2>/dev/null" >> /etc/crontab
                    fi
                fi
LEEOF
        } > /dev/null 2>&1 &
        show_progress $! "Configuring Let's Encrypt for ${LETSENCRYPT_DOMAIN}"
    fi

    print_success "Optional features configuration complete"
}

# =============================================================================
# Finalize configuration (SSH hardening and shutdown)
# =============================================================================

finalize_configuration() {
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

# =============================================================================
# Main configuration function (calls all stages)
# =============================================================================

configure_proxmox_via_ssh() {
    configure_base_system
    configure_network
    configure_optional_features
    finalize_configuration
}
