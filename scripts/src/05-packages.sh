# =============================================================================
# Package preparation and ISO download
# =============================================================================

prepare_packages() {
    echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve.list

    # Download Proxmox GPG key
    curl -fsSL -o /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg &
    show_progress $! "Downloading Proxmox GPG key"
    wait $!
    if [ $? -ne 0 ]; then
        echo -e "${CLR_RED}Failed to download Proxmox GPG key! Exiting.${CLR_RESET}"
        exit 1
    fi

    # Update package lists
    apt clean > /dev/null 2>&1
    apt update > /dev/null 2>&1 &
    show_progress $! "Updating package lists"
    wait $!
    if [ $? -ne 0 ]; then
        echo -e "${CLR_RED}Failed to update package lists! Exiting.${CLR_RESET}"
        exit 1
    fi

    # Install packages
    apt install -yq proxmox-auto-install-assistant xorriso ovmf wget sshpass > /dev/null 2>&1 &
    show_progress $! "Installing packages"
    wait $!
    if [ $? -ne 0 ]; then
        echo -e "${CLR_RED}Failed to install required packages! Exiting.${CLR_RESET}"
        exit 1
    fi
}

# Fetch latest Proxmox VE ISO
get_latest_proxmox_ve_iso() {
    local base_url="https://enterprise.proxmox.com/iso/"
    local latest_iso=$(curl -s "$base_url" | grep -oE 'proxmox-ve_[0-9]+\.[0-9]+-[0-9]+\.iso' | sort -V | tail -n1)

    if [[ -n "$latest_iso" ]]; then
        echo "${base_url}${latest_iso}"
    else
        echo "No Proxmox VE ISO found." >&2
        return 1
    fi
}

download_proxmox_iso() {
    if [[ -f "pve.iso" ]]; then
        echo -e "${CLR_GREEN}✓ Proxmox ISO already exists, skipping download${CLR_RESET}"
        return 0
    fi

    PROXMOX_ISO_URL=$(get_latest_proxmox_ve_iso)
    if [[ -z "$PROXMOX_ISO_URL" ]]; then
        echo -e "${CLR_RED}Failed to retrieve Proxmox ISO URL! Exiting.${CLR_RESET}"
        exit 1
    fi

    ISO_FILENAME=$(basename "$PROXMOX_ISO_URL")
    CHECKSUM_URL="https://enterprise.proxmox.com/iso/SHA256SUMS"

    # Download ISO with progress bar
    wget -q --show-progress -O pve.iso "$PROXMOX_ISO_URL" 2>&1 &
    show_progress $! "Downloading $ISO_FILENAME"
    wait $!
    if [[ $? -ne 0 ]]; then
        echo -e "${CLR_RED}Failed to download Proxmox ISO! Exiting.${CLR_RESET}"
        exit 1
    fi

    if [[ ! -s "pve.iso" ]]; then
        echo -e "${CLR_RED}Downloaded ISO file is empty or corrupted! Exiting.${CLR_RESET}"
        rm -f pve.iso
        exit 1
    fi

    # Verify ISO checksum with progress
    wget -q -O SHA256SUMS "$CHECKSUM_URL" 2>/dev/null &
    show_progress $! "Downloading checksum"
    wait $!

    if [[ -f "SHA256SUMS" ]]; then
        EXPECTED_CHECKSUM=$(grep "$ISO_FILENAME" SHA256SUMS | awk '{print $1}')
        if [[ -n "$EXPECTED_CHECKSUM" ]]; then
            sha256sum pve.iso > /tmp/iso_checksum.txt 2>/dev/null &
            show_progress $! "Verifying ISO checksum"
            wait $!
            ACTUAL_CHECKSUM=$(cat /tmp/iso_checksum.txt | awk '{print $1}')
            rm -f /tmp/iso_checksum.txt

            if [[ "$EXPECTED_CHECKSUM" == "$ACTUAL_CHECKSUM" ]]; then
                echo -e "${CLR_GREEN}✓ ISO checksum verified${CLR_RESET}"
            else
                echo -e "${CLR_RED}ISO checksum verification FAILED!${CLR_RESET}"
                echo -e "${CLR_RED}Expected: $EXPECTED_CHECKSUM${CLR_RESET}"
                echo -e "${CLR_RED}Actual:   $ACTUAL_CHECKSUM${CLR_RESET}"
                rm -f pve.iso SHA256SUMS
                exit 1
            fi
        else
            echo -e "${CLR_YELLOW}⚠ Could not find checksum for $ISO_FILENAME${CLR_RESET}"
        fi
        rm -f SHA256SUMS
    else
        echo -e "${CLR_YELLOW}⚠ Could not download checksum file${CLR_RESET}"
    fi
}

make_answer_toml() {
    echo -e "${CLR_BLUE}Making answer.toml...${CLR_RESET}"

    # Build disk_list based on detected drives (using vda/vdb for QEMU virtio)
    if [ "$RAID_MODE" = "raid1" ]; then
        DISK_LIST='["/dev/vda", "/dev/vdb"]'
        ZFS_RAID="raid1"
    else
        DISK_LIST='["/dev/vda"]'
        ZFS_RAID="single"
    fi

    cat <<EOF > answer.toml
[global]
    keyboard = "en-us"
    country = "us"
    fqdn = "$FQDN"
    mailto = "$EMAIL"
    timezone = "$TIMEZONE"
    root_password = "$NEW_ROOT_PASSWORD"
    reboot_on_error = false

[network]
    source = "from-dhcp"

[disk-setup]
    filesystem = "zfs"
    zfs.raid = "$ZFS_RAID"
    disk_list = $DISK_LIST

EOF
    echo -e "${CLR_GREEN}✓ answer.toml created (ZFS $ZFS_RAID mode)${CLR_RESET}"
}

make_autoinstall_iso() {
    echo -e "${CLR_BLUE}Making autoinstall.iso...${CLR_RESET}"
    proxmox-auto-install-assistant prepare-iso pve.iso --fetch-from iso --answer-file answer.toml --output pve-autoinstall.iso
    echo -e "${CLR_GREEN}✓ pve-autoinstall.iso created${CLR_RESET}"
}
