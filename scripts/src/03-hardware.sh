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

    # Collect drive info and find max model length
    local -a drive_names=()
    local -a drive_sizes=()
    local -a drive_models=()
    local max_model_len=10  # minimum width

    for drive in "${NVME_DRIVES[@]}"; do
        local name=$(basename "$drive")
        local size=$(lsblk -d -n -o SIZE "$drive" | xargs)
        local model=$(lsblk -d -n -o MODEL "$drive" 2>/dev/null | xargs || echo "NVMe")
        drive_names+=("$name")
        drive_sizes+=("$size")
        drive_models+=("$model")
        [[ ${#model} -gt $max_model_len ]] && max_model_len=${#model}
    done

    # Calculate table width: "  name(8)  size(5)  model  "
    local content_width=$((2 + 8 + 2 + 5 + 2 + max_model_len + 2))
    local min_width=35  # minimum for mode text
    [[ $content_width -lt $min_width ]] && content_width=$min_width

    # Draw table
    local border=$(printf '─%.0s' $(seq 1 $content_width))
    echo -e "${CLR_BLUE}┌${border}┐${CLR_RESET}"
    printf "${CLR_BLUE}│${CLR_RESET}  %-*s${CLR_BLUE}│${CLR_RESET}\n" $((content_width - 2)) "Storage Configuration"
    echo -e "${CLR_BLUE}├${border}┤${CLR_RESET}"

    for i in "${!drive_names[@]}"; do
        printf "${CLR_BLUE}│${CLR_RESET}  %-8s  %5s  %-*s  ${CLR_BLUE}│${CLR_RESET}\n" \
            "${drive_names[$i]}" "${drive_sizes[$i]}" "$max_model_len" "${drive_models[$i]}"
    done

    echo -e "${CLR_BLUE}├${border}┤${CLR_RESET}"

    if [ ${#NVME_DRIVES[@]} -lt 2 ]; then
        printf "${CLR_BLUE}│${CLR_RESET}  ${CLR_YELLOW}%-*s${CLR_RESET}  ${CLR_BLUE}│${CLR_RESET}\n" $((content_width - 4)) "Mode: Single Drive (no RAID)"
        RAID_MODE="single"
    else
        printf "${CLR_BLUE}│${CLR_RESET}  ${CLR_GREEN}%-*s${CLR_RESET}  ${CLR_BLUE}│${CLR_RESET}\n" $((content_width - 4)) "Mode: ZFS RAID-1 (mirror)"
        RAID_MODE="raid1"
    fi

    echo -e "${CLR_BLUE}└${border}┘${CLR_RESET}"
    echo ""

    # Set drive variables for QEMU
    NVME_DRIVE_1="${NVME_DRIVES[0]}"
    NVME_DRIVE_2="${NVME_DRIVES[1]:-}"
}
