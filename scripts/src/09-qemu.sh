# =============================================================================
# QEMU installation and boot functions
# =============================================================================

is_uefi_mode() {
    [[ -d /sys/firmware/efi ]]
}

# Configure QEMU settings (shared between install and boot)
setup_qemu_config() {
    log "=== Configuring QEMU settings ==="
    # UEFI configuration
    if is_uefi_mode; then
        UEFI_OPTS="-bios /usr/share/ovmf/OVMF.fd"
        log "UEFI mode detected"
    else
        UEFI_OPTS=""
        log "Legacy BIOS mode"
    fi

    # CPU and RAM configuration
    local available_cores=$(nproc)
    local available_ram_mb=$(free -m | awk '/^Mem:/{print $2}')

    QEMU_CORES=$((available_cores / 2))
    [[ $QEMU_CORES -lt 2 ]] && QEMU_CORES=2
    [[ $QEMU_CORES -gt $available_cores ]] && QEMU_CORES=$available_cores
    [[ $QEMU_CORES -gt 16 ]] && QEMU_CORES=16

    QEMU_RAM=8192
    [[ $available_ram_mb -lt 16384 ]] && QEMU_RAM=4096

    log "QEMU config: ${QEMU_CORES} vCPUs, ${QEMU_RAM}MB RAM"

    # Drive configuration
    DRIVE_ARGS="-drive file=$NVME_DRIVE_1,format=raw,media=disk,if=virtio"
    [[ -n "$NVME_DRIVE_2" ]] && DRIVE_ARGS="$DRIVE_ARGS -drive file=$NVME_DRIVE_2,format=raw,media=disk,if=virtio"
    log "Drive args: $DRIVE_ARGS"
}

# Install Proxmox via QEMU
install_proxmox() {
    log "=== Starting install_proxmox ==="
    setup_qemu_config

    # Run QEMU in background and show progress
    log "Starting QEMU for Proxmox installation"
    qemu-system-x86_64 -enable-kvm $UEFI_OPTS \
        -cpu host -smp $QEMU_CORES -m $QEMU_RAM \
        -boot d -cdrom ./pve-autoinstall.iso \
        $DRIVE_ARGS -no-reboot -display none > /dev/null 2>&1 &

    show_progress $! "Installing Proxmox VE (${QEMU_CORES} vCPUs, ${QEMU_RAM}MB RAM)" "Proxmox VE installed"
    log "QEMU installation process completed"
}

# Boot installed Proxmox with SSH port forwarding
boot_proxmox_with_port_forwarding() {
    log "=== Starting boot_proxmox_with_port_forwarding ==="
    setup_qemu_config

    log "Starting QEMU with SSH port forwarding (localhost:5555 -> VM:22)"
    nohup qemu-system-x86_64 -enable-kvm $UEFI_OPTS \
        -cpu host -device e1000,netdev=net0 \
        -netdev user,id=net0,hostfwd=tcp::5555-:22 \
        -smp $QEMU_CORES -m $QEMU_RAM \
        $DRIVE_ARGS -display none \
        > qemu_output.log 2>&1 &

    QEMU_PID=$!
    log "QEMU PID: $QEMU_PID"

    # Wait for actual SSH connection (not just TCP port)
    # Using 150 attempts (5 minutes) since VM boot takes time
    log "Waiting for SSH to become available on port 5555"
    wait_for_ssh_ready 150 "Booting Proxmox VM" "Proxmox booted, SSH available" || {
        print_error "Failed to connect to VM via SSH. Check if VM is running properly."
        exit 1
    }
    log "SSH is available"
}
