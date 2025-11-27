# =============================================================================
# System info collection with progress
# =============================================================================

collect_system_info() {
    local errors=0
    local checks=6
    local current=0
    local spinner='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0

    # Progress update helper
    update_progress() {
        current=$((current + 1))
        local pct=$((current * 100 / checks))
        local filled=$((pct / 5))
        local empty=$((20 - filled))
        printf "\r${CLR_YELLOW}${spinner:i++%${#spinner}:1} Checking system... [${CLR_GREEN}"
        printf '█%.0s' $(seq 1 $filled 2>/dev/null) 2>/dev/null || true
        printf "${CLR_RESET}${CLR_BLUE}"
        printf '░%.0s' $(seq 1 $empty 2>/dev/null) 2>/dev/null || true
        printf "${CLR_RESET}${CLR_YELLOW}] %3d%%${CLR_RESET}" "$pct"
    }

    # Check if running as root
    update_progress
    if [[ $EUID -ne 0 ]]; then
        PREFLIGHT_ROOT="✗ Not root"
        PREFLIGHT_ROOT_CLR="${CLR_RED}"
        errors=$((errors + 1))
    else
        PREFLIGHT_ROOT="✓ Running as root"
        PREFLIGHT_ROOT_CLR="${CLR_GREEN}"
    fi
    sleep 0.1

    # Check internet connectivity
    update_progress
    if ping -c 1 -W 3 1.1.1.1 > /dev/null 2>&1; then
        PREFLIGHT_NET="✓ Available"
        PREFLIGHT_NET_CLR="${CLR_GREEN}"
    else
        PREFLIGHT_NET="✗ No connection"
        PREFLIGHT_NET_CLR="${CLR_RED}"
        errors=$((errors + 1))
    fi

    # Check available disk space (need at least 5GB in /root)
    update_progress
    local free_space_mb=$(df -m /root | awk 'NR==2 {print $4}')
    if [[ $free_space_mb -ge 5000 ]]; then
        PREFLIGHT_DISK="✓ ${free_space_mb} MB"
        PREFLIGHT_DISK_CLR="${CLR_GREEN}"
    else
        PREFLIGHT_DISK="✗ ${free_space_mb} MB (need 5GB+)"
        PREFLIGHT_DISK_CLR="${CLR_RED}"
        errors=$((errors + 1))
    fi
    sleep 0.1

    # Check RAM (need at least 4GB)
    update_progress
    local total_ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    if [[ $total_ram_mb -ge 4000 ]]; then
        PREFLIGHT_RAM="✓ ${total_ram_mb} MB"
        PREFLIGHT_RAM_CLR="${CLR_GREEN}"
    else
        PREFLIGHT_RAM="✗ ${total_ram_mb} MB (need 4GB+)"
        PREFLIGHT_RAM_CLR="${CLR_RED}"
        errors=$((errors + 1))
    fi
    sleep 0.1

    # Check CPU cores
    update_progress
    local cpu_cores=$(nproc)
    if [[ $cpu_cores -ge 2 ]]; then
        PREFLIGHT_CPU="✓ ${cpu_cores} cores"
        PREFLIGHT_CPU_CLR="${CLR_GREEN}"
    else
        PREFLIGHT_CPU="⚠ ${cpu_cores} core(s)"
        PREFLIGHT_CPU_CLR="${CLR_YELLOW}"
    fi
    sleep 0.1

    # Check if KVM is available
    update_progress
    if [[ -e /dev/kvm ]]; then
        PREFLIGHT_KVM="✓ Available"
        PREFLIGHT_KVM_CLR="${CLR_GREEN}"
    else
        PREFLIGHT_KVM="✗ Not available"
        PREFLIGHT_KVM_CLR="${CLR_RED}"
        errors=$((errors + 1))
    fi
    sleep 0.1

    # Clear progress line
    printf "\r\033[K"

    PREFLIGHT_ERRORS=$errors
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

validate_password() {
    local password="$1"
    # Password must contain only ASCII printable characters (no Cyrillic or other non-ASCII)
    # Allowed: Latin letters, digits, and special characters (ASCII 32-126)
    # Using LC_ALL=C ensures only ASCII characters match [:print:]
    if ! LC_ALL=C bash -c '[[ "$1" =~ ^[[:print:]]+$ ]]' _ "$password"; then
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
