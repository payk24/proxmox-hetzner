# =============================================================================
# System status display
# =============================================================================

show_system_status() {
    # Find all NVMe drives (excluding partitions)
    NVME_DRIVES=($(lsblk -d -n -o NAME,TYPE | grep nvme | grep disk | awk '{print "/dev/"$1}' | sort))

    local nvme_error=0
    if [ ${#NVME_DRIVES[@]} -eq 0 ]; then
        nvme_error=1
    fi

    # Collect drive info
    local -a drive_names=()
    local -a drive_sizes=()
    local -a drive_models=()
    local max_model_len=10

    for drive in "${NVME_DRIVES[@]}"; do
        local name=$(basename "$drive")
        local size=$(lsblk -d -n -o SIZE "$drive" | xargs)
        local model=$(lsblk -d -n -o MODEL "$drive" 2>/dev/null | xargs || echo "NVMe")
        drive_names+=("$name")
        drive_sizes+=("$size")
        drive_models+=("$model")
        [[ ${#model} -gt $max_model_len ]] && max_model_len=${#model}
    done

    # Determine RAID mode
    if [ ${#NVME_DRIVES[@]} -lt 2 ]; then
        RAID_MODE="single"
    else
        RAID_MODE="raid1"
    fi

    # Print combined system info table
    echo -e "${CLR_BLUE}┌─────────────────────────────────────────────────────┐${CLR_RESET}"
    echo -e "${CLR_BLUE}│${CLR_RESET}  ${CLR_CYAN}System Information${CLR_RESET}                                 ${CLR_BLUE}│${CLR_RESET}"
    echo -e "${CLR_BLUE}├───────────────────┬─────────────────────────────────┤${CLR_RESET}"
    printf "${CLR_BLUE}│${CLR_RESET} %-17s ${CLR_BLUE}│${CLR_RESET} ${PREFLIGHT_ROOT_CLR}%-31s${CLR_RESET} ${CLR_BLUE}│${CLR_RESET}\n" "Root Access" "$PREFLIGHT_ROOT"
    printf "${CLR_BLUE}│${CLR_RESET} %-17s ${CLR_BLUE}│${CLR_RESET} ${PREFLIGHT_NET_CLR}%-31s${CLR_RESET} ${CLR_BLUE}│${CLR_RESET}\n" "Internet" "$PREFLIGHT_NET"
    printf "${CLR_BLUE}│${CLR_RESET} %-17s ${CLR_BLUE}│${CLR_RESET} ${PREFLIGHT_DISK_CLR}%-31s${CLR_RESET} ${CLR_BLUE}│${CLR_RESET}\n" "Disk Space" "$PREFLIGHT_DISK"
    printf "${CLR_BLUE}│${CLR_RESET} %-17s ${CLR_BLUE}│${CLR_RESET} ${PREFLIGHT_RAM_CLR}%-31s${CLR_RESET} ${CLR_BLUE}│${CLR_RESET}\n" "RAM" "$PREFLIGHT_RAM"
    printf "${CLR_BLUE}│${CLR_RESET} %-17s ${CLR_BLUE}│${CLR_RESET} ${PREFLIGHT_CPU_CLR}%-31s${CLR_RESET} ${CLR_BLUE}│${CLR_RESET}\n" "CPU" "$PREFLIGHT_CPU"
    printf "${CLR_BLUE}│${CLR_RESET} %-17s ${CLR_BLUE}│${CLR_RESET} ${PREFLIGHT_KVM_CLR}%-31s${CLR_RESET} ${CLR_BLUE}│${CLR_RESET}\n" "KVM" "$PREFLIGHT_KVM"
    echo -e "${CLR_BLUE}├───────────────────┴─────────────────────────────────┤${CLR_RESET}"
    echo -e "${CLR_BLUE}│${CLR_RESET}  ${CLR_CYAN}Storage${CLR_RESET}                                            ${CLR_BLUE}│${CLR_RESET}"
    echo -e "${CLR_BLUE}├─────────────────────────────────────────────────────┤${CLR_RESET}"

    if [ $nvme_error -eq 1 ]; then
        printf "${CLR_BLUE}│${CLR_RESET}  ${CLR_RED}%-49s${CLR_RESET}  ${CLR_BLUE}│${CLR_RESET}\n" "✗ No NVMe drives detected!"
    else
        for i in "${!drive_names[@]}"; do
            printf "${CLR_BLUE}│${CLR_RESET}  ${CLR_GREEN}✓${CLR_RESET} %-8s  %5s  %-28s  ${CLR_BLUE}│${CLR_RESET}\n" \
                "${drive_names[$i]}" "${drive_sizes[$i]}" "${drive_models[$i]:0:28}"
        done
    fi

    echo -e "${CLR_BLUE}├─────────────────────────────────────────────────────┤${CLR_RESET}"
    if [ "$RAID_MODE" = "single" ]; then
        printf "${CLR_BLUE}│${CLR_RESET}  ${CLR_YELLOW}%-49s${CLR_RESET}  ${CLR_BLUE}│${CLR_RESET}\n" "Mode: Single Drive (no RAID)"
    else
        printf "${CLR_BLUE}│${CLR_RESET}  ${CLR_GREEN}%-49s${CLR_RESET}  ${CLR_BLUE}│${CLR_RESET}\n" "Mode: ZFS RAID-1 (mirror)"
    fi
    echo -e "${CLR_BLUE}└─────────────────────────────────────────────────────┘${CLR_RESET}"
    echo ""

    # Check for errors
    if [[ $PREFLIGHT_ERRORS -gt 0 ]]; then
        echo -e "${CLR_RED}Pre-flight checks failed with $PREFLIGHT_ERRORS error(s). Exiting.${CLR_RESET}"
        exit 1
    fi

    if [ $nvme_error -eq 1 ]; then
        echo -e "${CLR_RED}No NVMe drives detected! Exiting.${CLR_RESET}"
        exit 1
    fi

    echo -e "${CLR_GREEN}✓ All checks passed!${CLR_RESET}"
    echo ""

    # Set drive variables for QEMU
    NVME_DRIVE_1="${NVME_DRIVES[0]}"
    NVME_DRIVE_2="${NVME_DRIVES[1]:-}"
}
