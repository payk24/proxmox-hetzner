# =============================================================================
# Hardware detection
# =============================================================================

detect_nvme_drives() {
    echo -e "${CLR_BLUE}Detecting NVMe drives...${CLR_RESET}"

    # Find all NVMe drives (excluding partitions)
    NVME_DRIVES=($(lsblk -d -n -o NAME,TYPE | grep nvme | grep disk | awk '{print "/dev/"$1}' | sort))

    if [ ${#NVME_DRIVES[@]} -eq 0 ]; then
        echo -e "${CLR_RED}No NVMe drives detected! Exiting.${CLR_RESET}"
        exit 1
    fi

    echo -e "${CLR_GREEN}Detected ${#NVME_DRIVES[@]} NVMe drive(s):${CLR_RESET}"
    for drive in "${NVME_DRIVES[@]}"; do
        local size=$(lsblk -d -n -o SIZE "$drive")
        echo "  - $drive ($size)"
    done

    if [ ${#NVME_DRIVES[@]} -lt 2 ]; then
        echo -e "${CLR_YELLOW}Warning: Only ${#NVME_DRIVES[@]} NVMe drive detected. RAID-1 requires 2 drives.${CLR_RESET}"
        echo -e "${CLR_YELLOW}Installation will proceed with single drive (no RAID).${CLR_RESET}"
        RAID_MODE="single"
    else
        RAID_MODE="raid1"
    fi

    # Set drive variables for QEMU
    NVME_DRIVE_1="${NVME_DRIVES[0]}"
    NVME_DRIVE_2="${NVME_DRIVES[1]:-}"
}

# Ensure the script is run as root
if [[ $EUID != 0 ]]; then
    echo -e "${CLR_RED}Please run this script as root.${CLR_RESET}"
    exit 1
fi

echo -e "${CLR_GREEN}Starting Proxmox auto-installation...${CLR_RESET}"
