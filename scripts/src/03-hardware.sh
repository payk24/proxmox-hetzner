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

    for drive in "${NVME_DRIVES[@]}"; do
        local name=$(basename "$drive")
        local size=$(lsblk -d -n -o SIZE "$drive" | xargs)
        local model=$(lsblk -d -n -o MODEL "$drive" 2>/dev/null | xargs || echo "NVMe")
        drive_names+=("$name")
        drive_sizes+=("$size")
        drive_models+=("$model")
    done

    # Determine RAID mode
    if [ ${#NVME_DRIVES[@]} -lt 2 ]; then
        RAID_MODE="single"
    else
        RAID_MODE="raid1"
    fi

    # Print combined system info table using helper functions
    table_top
    table_header "System Information"
    table_separator_cols
    table_row "Root Access" "$PREFLIGHT_ROOT" "$PREFLIGHT_ROOT_CLR"
    table_row "Internet" "$PREFLIGHT_NET" "$PREFLIGHT_NET_CLR"
    table_row "Disk Space" "$PREFLIGHT_DISK" "$PREFLIGHT_DISK_CLR"
    table_row "RAM" "$PREFLIGHT_RAM" "$PREFLIGHT_RAM_CLR"
    table_row "CPU" "$PREFLIGHT_CPU" "$PREFLIGHT_CPU_CLR"
    table_row "KVM" "$PREFLIGHT_KVM" "$PREFLIGHT_KVM_CLR"
    table_separator_cols_end
    table_header "Storage"
    table_separator

    if [ $nvme_error -eq 1 ]; then
        table_row_full "✗ No NVMe drives detected!" "$CLR_RED"
    else
        for i in "${!drive_names[@]}"; do
            local drive_info=$(printf "✓ %-10s %5s  %s" "${drive_names[$i]}" "${drive_sizes[$i]}" "${drive_models[$i]:0:30}")
            table_row_full "$drive_info" "$CLR_GREEN"
        done
    fi

    table_separator
    if [ "$RAID_MODE" = "single" ]; then
        table_row_full "Mode: Single Drive (no RAID)" "$CLR_YELLOW"
    else
        table_row_full "Mode: ZFS RAID-1 (mirror)" "$CLR_GREEN"
    fi
    table_bottom
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
