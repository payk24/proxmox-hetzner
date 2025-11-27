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

    # Store drive count for RAID mode selection (done in get_system_inputs)
    NVME_COUNT=${#NVME_DRIVES[@]}

    # Set default RAID mode if not already set
    if [ -z "$ZFS_RAID" ]; then
        if [ $NVME_COUNT -lt 2 ]; then
            ZFS_RAID="single"
        else
            ZFS_RAID="raid1"
        fi
    fi

    # Build system info using column for alignment
    local sys_rows=""

    # Root access
    if [[ "$PREFLIGHT_ROOT" == *"Running as root"* ]]; then
        sys_rows+="[OK]|Root Access|Running as root"$'\n'
    else
        sys_rows+="[ERROR]|Root Access|Not root"$'\n'
    fi

    # Internet
    if [[ "$PREFLIGHT_NET" == *"Available"* ]]; then
        sys_rows+="[OK]|Internet|Available"$'\n'
    else
        sys_rows+="[ERROR]|Internet|No connection"$'\n'
    fi

    # Temp space (rescue system free space for downloading ISO)
    if [[ "$PREFLIGHT_DISK" == *"✓"* ]]; then
        local disk_val="${PREFLIGHT_DISK#✓ }"
        sys_rows+="[OK]|Temp Space|${disk_val}"$'\n'
    else
        local disk_val="${PREFLIGHT_DISK#✗ }"
        sys_rows+="[ERROR]|Temp Space|${disk_val}"$'\n'
    fi

    # RAM
    if [[ "$PREFLIGHT_RAM" == *"✓"* ]]; then
        local ram_val="${PREFLIGHT_RAM#✓ }"
        sys_rows+="[OK]|RAM|${ram_val}"$'\n'
    else
        local ram_val="${PREFLIGHT_RAM#✗ }"
        sys_rows+="[ERROR]|RAM|${ram_val}"$'\n'
    fi

    # CPU
    if [[ "$PREFLIGHT_CPU" == *"✓"* ]]; then
        local cpu_val="${PREFLIGHT_CPU#✓ }"
        sys_rows+="[OK]|CPU|${cpu_val}"$'\n'
    elif [[ "$PREFLIGHT_CPU" == *"⚠"* ]]; then
        local cpu_val="${PREFLIGHT_CPU#⚠ }"
        sys_rows+="[WARN]|CPU|${cpu_val}"$'\n'
    else
        local cpu_val="${PREFLIGHT_CPU#✗ }"
        sys_rows+="[ERROR]|CPU|${cpu_val}"$'\n'
    fi

    # KVM
    if [[ "$PREFLIGHT_KVM" == *"Available"* ]]; then
        sys_rows+="[OK]|KVM|Available"
    else
        sys_rows+="[ERROR]|KVM|Not available"
    fi

    # Build storage rows (Mode will be selected interactively in get_system_inputs)
    local storage_rows=""
    if [ $nvme_error -eq 1 ]; then
        storage_rows="[ERROR]|No NVMe drives detected!|"
    else
        for i in "${!drive_names[@]}"; do
            # Format: [OK] name "size  model" - combined for alignment with sys_rows
            storage_rows+="[OK]|${drive_names[$i]}|${drive_sizes[$i]}  ${drive_models[$i]:0:25}"
            # Add newline only if not the last item
            if [ $i -lt $((${#drive_names[@]} - 1)) ]; then
                storage_rows+=$'\n'
            fi
        done
    fi

    # Display with boxes and colorize - combine all rows for uniform column alignment
    {
        echo "SYSTEM INFORMATION"
        {
            echo "$sys_rows"
            echo "|--- Storage ---|"
            echo "$storage_rows"
        } | column -t -s '|'
    } | boxes -d stone -p a1 | colorize_status
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

    echo -e "${CLR_GREEN}All checks passed!${CLR_RESET}"
    echo ""

    # Set drive variables for QEMU
    NVME_DRIVE_1="${NVME_DRIVES[0]}"
    NVME_DRIVE_2="${NVME_DRIVES[1]:-}"
}
