# =============================================================================
# Hardware detection
# =============================================================================

detect_nvme_drives() {
    # Find all NVMe drives (excluding partitions)
    NVME_DRIVES=($(lsblk -d -n -o NAME,TYPE | grep nvme | grep disk | awk '{print "/dev/"$1}' | sort))

    if [ ${#NVME_DRIVES[@]} -eq 0 ]; then
        echo -e "${CLR_RED}✗ No NVMe drives detected! Exiting.${CLR_RESET}"
        exit 1
    fi

    echo -e "${CLR_BLUE}┌─────────────────────────────────────────┐${CLR_RESET}"
    echo -e "${CLR_BLUE}│  Storage Configuration                  │${CLR_RESET}"
    echo -e "${CLR_BLUE}├─────────────────────────────────────────┤${CLR_RESET}"

    for drive in "${NVME_DRIVES[@]}"; do
        local size=$(lsblk -d -n -o SIZE "$drive" | xargs)
        local model=$(lsblk -d -n -o MODEL "$drive" 2>/dev/null | xargs || echo "NVMe")
        printf "${CLR_BLUE}│${CLR_RESET}  %-8s  %5s  %-22.22s${CLR_BLUE}│${CLR_RESET}\n" "$(basename $drive)" "$size" "$model"
    done

    echo -e "${CLR_BLUE}├─────────────────────────────────────────┤${CLR_RESET}"

    if [ ${#NVME_DRIVES[@]} -lt 2 ]; then
        echo -e "${CLR_BLUE}│${CLR_RESET}  ${CLR_YELLOW}Mode: Single Drive (no RAID)${CLR_RESET}           ${CLR_BLUE}│${CLR_RESET}"
        RAID_MODE="single"
    else
        echo -e "${CLR_BLUE}│${CLR_RESET}  ${CLR_GREEN}Mode: ZFS RAID-1 (mirror)${CLR_RESET}              ${CLR_BLUE}│${CLR_RESET}"
        RAID_MODE="raid1"
    fi

    echo -e "${CLR_BLUE}└─────────────────────────────────────────┘${CLR_RESET}"
    echo ""

    # Set drive variables for QEMU
    NVME_DRIVE_1="${NVME_DRIVES[0]}"
    NVME_DRIVE_2="${NVME_DRIVES[1]:-}"
}
