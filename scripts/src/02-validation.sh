# =============================================================================
# Pre-flight checks
# =============================================================================

preflight_checks() {
    echo -e "${CLR_BLUE}Running pre-flight checks...${CLR_RESET}"
    echo ""
    local errors=0

    # Gather system information
    local root_status="" root_color=""
    local net_status="" net_color=""
    local disk_status="" disk_color=""
    local ram_status="" ram_color=""
    local cpu_status="" cpu_color=""
    local kvm_status="" kvm_color=""

    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        root_status="✗ Not root"
        root_color="${CLR_RED}"
        errors=$((errors + 1))
    else
        root_status="✓ Running as root"
        root_color="${CLR_GREEN}"
    fi

    # Check internet connectivity
    if ping -c 1 -W 3 1.1.1.1 > /dev/null 2>&1; then
        net_status="✓ Available"
        net_color="${CLR_GREEN}"
    else
        net_status="✗ No connection"
        net_color="${CLR_RED}"
        errors=$((errors + 1))
    fi

    # Check available disk space (need at least 5GB in /root)
    local free_space_mb=$(df -m /root | awk 'NR==2 {print $4}')
    if [[ $free_space_mb -ge 5000 ]]; then
        disk_status="✓ ${free_space_mb} MB"
        disk_color="${CLR_GREEN}"
    else
        disk_status="✗ ${free_space_mb} MB (need 5GB+)"
        disk_color="${CLR_RED}"
        errors=$((errors + 1))
    fi

    # Check RAM (need at least 4GB)
    local total_ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    if [[ $total_ram_mb -ge 4000 ]]; then
        ram_status="✓ ${total_ram_mb} MB"
        ram_color="${CLR_GREEN}"
    else
        ram_status="✗ ${total_ram_mb} MB (need 4GB+)"
        ram_color="${CLR_RED}"
        errors=$((errors + 1))
    fi

    # Check CPU cores
    local cpu_cores=$(nproc)
    if [[ $cpu_cores -ge 2 ]]; then
        cpu_status="✓ ${cpu_cores} cores"
        cpu_color="${CLR_GREEN}"
    else
        cpu_status="⚠ ${cpu_cores} core(s)"
        cpu_color="${CLR_YELLOW}"
    fi

    # Check if KVM is available
    if [[ -e /dev/kvm ]]; then
        kvm_status="✓ Available"
        kvm_color="${CLR_GREEN}"
    else
        kvm_status="✗ Not available"
        kvm_color="${CLR_RED}"
        errors=$((errors + 1))
    fi

    # Print table
    echo -e "┌───────────────────┬────────────────────────────┐"
    echo -e "│ ${CLR_CYAN}Check${CLR_RESET}             │ ${CLR_CYAN}Status${CLR_RESET}                     │"
    echo -e "├───────────────────┼────────────────────────────┤"
    printf "│ %-17s │ ${root_color}%-19s${CLR_RESET}        │\n" "Root Access" "$root_status"
    printf "│ %-17s │ ${net_color}%-19s${CLR_RESET}        │\n" "Internet" "$net_status"
    printf "│ %-17s │ ${disk_color}%-19s${CLR_RESET}        │\n" "Disk Space" "$disk_status"
    printf "│ %-17s │ ${ram_color}%-19s${CLR_RESET}        │\n" "RAM" "$ram_status"
    printf "│ %-17s │ ${cpu_color}%-19s${CLR_RESET}        │\n" "CPU" "$cpu_status"
    printf "│ %-17s │ ${kvm_color}%-19s${CLR_RESET}        │\n" "KVM" "$kvm_status"
    echo -e "└───────────────────┴────────────────────────────┘"
    echo ""

    if [[ $errors -gt 0 ]]; then
        echo -e "${CLR_RED}Pre-flight checks failed with $errors error(s). Exiting.${CLR_RESET}"
        exit 1
    fi

    echo -e "${CLR_GREEN}✓ All pre-flight checks passed!${CLR_RESET}"
    echo ""
}

# =============================================================================
# Input validation functions
# =============================================================================

validate_hostname() {
    local hostname="$1"
    # Hostname: alphanumeric and hyphens, 1-63 chars, cannot start/end with hyphen
    if [[ ! "$hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        return 1
    fi
    return 0
}

validate_fqdn() {
    local fqdn="$1"
    # FQDN: valid hostname labels separated by dots
    if [[ ! "$fqdn" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]; then
        return 1
    fi
    return 0
}

validate_email() {
    local email="$1"
    # Basic email validation
    if [[ ! "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 1
    fi
    return 0
}

validate_subnet() {
    local subnet="$1"
    # Validate CIDR notation (e.g., 10.0.0.0/24)
    if [[ ! "$subnet" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]; then
        return 1
    fi
    # Validate each octet is 0-255 using parameter expansion (no read/IFS to avoid terminal issues)
    local ip="${subnet%/*}"
    local octet1 octet2 octet3 octet4 temp
    octet1="${ip%%.*}"
    temp="${ip#*.}"
    octet2="${temp%%.*}"
    temp="${temp#*.}"
    octet3="${temp%%.*}"
    octet4="${temp#*.}"

    if [ "$octet1" -gt 255 ] || [ "$octet2" -gt 255 ] || [ "$octet3" -gt 255 ] || [ "$octet4" -gt 255 ]; then
        return 1
    fi
    return 0
}

validate_timezone() {
    local tz="$1"
    # Check if timezone file exists (preferred validation)
    if [[ -f "/usr/share/zoneinfo/$tz" ]]; then
        return 0
    fi
    # Fallback: In Rescue System, zoneinfo may not be available
    # Validate format (Region/City or Region/Subregion/City)
    if [[ "$tz" =~ ^[A-Za-z_]+/[A-Za-z_]+(/[A-Za-z_]+)?$ ]]; then
        echo -e "${CLR_YELLOW}Note: Cannot verify timezone in Rescue System, format looks valid.${CLR_RESET}"
        return 0
    fi
    return 1
}
