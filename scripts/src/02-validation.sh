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
    # Validate each octet is 0-255
    local ip="${subnet%/*}"
    IFS='.' read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        if [ "$octet" -gt 255 ]; then
            return 1
        fi
    done
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
