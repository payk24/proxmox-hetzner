# =============================================================================
# Pre-flight checks
# =============================================================================

preflight_checks() {
    echo -e "${CLR_BLUE}Running pre-flight checks...${CLR_RESET}"
    local errors=0

    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        echo -e "${CLR_RED}✗ Must run as root${CLR_RESET}"
        errors=$((errors + 1))
    else
        echo -e "${CLR_GREEN}✓ Running as root${CLR_RESET}"
    fi

    # Check internet connectivity
    if ping -c 1 -W 3 1.1.1.1 > /dev/null 2>&1; then
        echo -e "${CLR_GREEN}✓ Internet connection available${CLR_RESET}"
    else
        echo -e "${CLR_RED}✗ No internet connection${CLR_RESET}"
        errors=$((errors + 1))
    fi

    # Check available disk space (need at least 5GB in /root)
    local free_space_mb=$(df -m /root | awk 'NR==2 {print $4}')
    if [[ $free_space_mb -ge 5000 ]]; then
        echo -e "${CLR_GREEN}✓ Disk space: ${free_space_mb}MB available${CLR_RESET}"
    else
        echo -e "${CLR_RED}✗ Insufficient disk space: ${free_space_mb}MB (need 5GB+)${CLR_RESET}"
        errors=$((errors + 1))
    fi

    # Check RAM (need at least 4GB)
    local total_ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    if [[ $total_ram_mb -ge 4000 ]]; then
        echo -e "${CLR_GREEN}✓ RAM: ${total_ram_mb}MB available${CLR_RESET}"
    else
        echo -e "${CLR_RED}✗ Insufficient RAM: ${total_ram_mb}MB (need 4GB+)${CLR_RESET}"
        errors=$((errors + 1))
    fi

    # Check CPU cores
    local cpu_cores=$(nproc)
    if [[ $cpu_cores -ge 2 ]]; then
        echo -e "${CLR_GREEN}✓ CPU: ${cpu_cores} cores${CLR_RESET}"
    else
        echo -e "${CLR_YELLOW}⚠ CPU: ${cpu_cores} core(s) - minimum 2 recommended${CLR_RESET}"
    fi

    # Check if KVM is available
    if [[ -e /dev/kvm ]]; then
        echo -e "${CLR_GREEN}✓ KVM virtualization available${CLR_RESET}"
    else
        echo -e "${CLR_RED}✗ KVM not available (required for installation)${CLR_RESET}"
        errors=$((errors + 1))
    fi

    # Check required commands
    for cmd in curl wget ip; do
        if command -v $cmd > /dev/null 2>&1; then
            echo -e "${CLR_GREEN}✓ Command '$cmd' available${CLR_RESET}"
        else
            echo -e "${CLR_RED}✗ Command '$cmd' not found${CLR_RESET}"
            errors=$((errors + 1))
        fi
    done

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
