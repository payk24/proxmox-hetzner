#!/usr/bin/env bash
set -e
cd /root

# Define colors for output
CLR_RED="\033[1;31m"
CLR_GREEN="\033[1;32m"
CLR_YELLOW="\033[1;33m"
CLR_BLUE="\033[1;34m"
CLR_RESET="\033[m"

clear

# Function to download files with error handling
download_file() {
    local output_file="$1"
    local url="$2"
    local max_retries=3
    local retry_count=0

    while [ $retry_count -lt $max_retries ]; do
        if wget -q -O "$output_file" "$url"; then
            if [ -s "$output_file" ]; then
                return 0
            else
                echo -e "${CLR_RED}Downloaded file is empty: $output_file${CLR_RESET}"
            fi
        else
            echo -e "${CLR_YELLOW}Download failed (attempt $((retry_count + 1))/$max_retries): $url${CLR_RESET}"
        fi
        retry_count=$((retry_count + 1))
        [ $retry_count -lt $max_retries ] && sleep 2
    done

    echo -e "${CLR_RED}Failed to download $url after $max_retries attempts. Exiting.${CLR_RESET}"
    exit 1
}

# Input validation functions
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

# Function to detect NVMe drives
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

# Function to get user input
get_system_inputs() {
    # Get default interface name and available alternative names first
    DEFAULT_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
    if [ -z "$DEFAULT_INTERFACE" ]; then
        DEFAULT_INTERFACE=$(udevadm info -e | grep -m1 -A 20 ^P.*eth0 | grep ID_NET_NAME_PATH | cut -d'=' -f2)
    fi
    
    # Get all available interfaces and their altnames
    AVAILABLE_ALTNAMES=$(ip -d link show | grep -v "lo:" | grep -E '(^[0-9]+:|altname)' | awk '/^[0-9]+:/ {interface=$2; gsub(/:/, "", interface); printf "%s", interface} /altname/ {printf ", %s", $2} END {print ""}' | sed 's/, $//')
    
    # Set INTERFACE_NAME to default if not already set
    if [ -z "$INTERFACE_NAME" ]; then
        INTERFACE_NAME="$DEFAULT_INTERFACE"
    fi
    
    # Prompt user for interface name
    read -e -p "Interface name (options are: ${AVAILABLE_ALTNAMES}) : " -i "$INTERFACE_NAME" INTERFACE_NAME
    
    # Now get network information based on the selected interface
    MAIN_IPV4_CIDR=$(ip address show "$INTERFACE_NAME" | grep global | grep "inet " | xargs | cut -d" " -f2)
    MAIN_IPV4=$(echo "$MAIN_IPV4_CIDR" | cut -d'/' -f1)
    MAIN_IPV4_GW=$(ip route | grep default | xargs | cut -d" " -f3)
    MAC_ADDRESS=$(ip link show "$INTERFACE_NAME" | awk '/ether/ {print $2}')
    IPV6_CIDR=$(ip address show "$INTERFACE_NAME" | grep global | grep "inet6 " | xargs | cut -d" " -f2)
    MAIN_IPV6=$(echo "$IPV6_CIDR" | cut -d'/' -f1)

    # Set a default value for FIRST_IPV6_CIDR even if IPV6_CIDR is empty
    if [ -n "$IPV6_CIDR" ]; then
        FIRST_IPV6_CIDR="$(echo "$IPV6_CIDR" | cut -d'/' -f1 | cut -d':' -f1-4):1::1/80"
    else
        FIRST_IPV6_CIDR=""
    fi

    # Display detected information
    echo -e "${CLR_YELLOW}Detected Network Information:${CLR_RESET}"
    echo "Interface Name: $INTERFACE_NAME"
    echo "Main IPv4 CIDR: $MAIN_IPV4_CIDR"
    echo "Main IPv4: $MAIN_IPV4"
    echo "Main IPv4 Gateway: $MAIN_IPV4_GW"
    echo "MAC Address: $MAC_ADDRESS"
    echo "IPv6 CIDR: $IPV6_CIDR"
    echo "IPv6: $MAIN_IPV6"

    # Get user input for other configuration with validation
    while true; do
        read -e -p "Enter your hostname : " -i "proxmox-example" HOSTNAME
        if validate_hostname "$HOSTNAME"; then
            break
        fi
        echo -e "${CLR_RED}Invalid hostname. Use only letters, numbers, and hyphens (1-63 chars, cannot start/end with hyphen).${CLR_RESET}"
    done

    while true; do
        read -e -p "Enter your FQDN name : " -i "proxmox.example.com" FQDN
        if validate_fqdn "$FQDN"; then
            break
        fi
        echo -e "${CLR_RED}Invalid FQDN. Use format: hostname.domain.tld${CLR_RESET}"
    done

    while true; do
        read -e -p "Enter your timezone : " -i "Europe/Istanbul" TIMEZONE
        if validate_timezone "$TIMEZONE"; then
            break
        fi
        echo -e "${CLR_RED}Invalid timezone. Use format like: Europe/London, America/New_York, Asia/Tokyo${CLR_RESET}"
    done

    while true; do
        read -e -p "Enter your email address: " -i "admin@example.com" EMAIL
        if validate_email "$EMAIL"; then
            break
        fi
        echo -e "${CLR_RED}Invalid email address format.${CLR_RESET}"
    done

    while true; do
        read -e -p "Enter your private subnet : " -i "10.0.0.0/24" PRIVATE_SUBNET
        if validate_subnet "$PRIVATE_SUBNET"; then
            break
        fi
        echo -e "${CLR_RED}Invalid subnet. Use CIDR format like: 10.0.0.0/24, 192.168.1.0/24${CLR_RESET}"
    done

    read -e -s -p "Enter your System New root password: " NEW_ROOT_PASSWORD
    echo ""

    # Get the network prefix (first three octets) from PRIVATE_SUBNET
    PRIVATE_CIDR=$(echo "$PRIVATE_SUBNET" | cut -d'/' -f1 | rev | cut -d'.' -f2- | rev)
    # Append .1 to get the first IP in the subnet
    PRIVATE_IP="${PRIVATE_CIDR}.1"
    # Get the subnet mask length
    SUBNET_MASK=$(echo "$PRIVATE_SUBNET" | cut -d'/' -f2)
    # Create the full CIDR notation for the first IP
    PRIVATE_IP_CIDR="${PRIVATE_IP}/${SUBNET_MASK}"
    
    # Check password was not empty, do it in loop until password is not empty
    while [[ -z "$NEW_ROOT_PASSWORD" ]]; do
        # Print message in a new line
        read -e -s -p "Enter your System New root password: " NEW_ROOT_PASSWORD
        echo ""
    done

    echo ""
    echo "Private subnet: $PRIVATE_SUBNET"
    echo "First IP in subnet (CIDR): $PRIVATE_IP_CIDR"

    # SSH Public Key (required for hardened SSH config)
    echo ""
    echo -e "${CLR_YELLOW}============================================${CLR_RESET}"
    echo -e "${CLR_YELLOW}  SSH Public Key Configuration${CLR_RESET}"
    echo -e "${CLR_YELLOW}============================================${CLR_RESET}"
    echo -e "${CLR_RED}Password authentication will be DISABLED!${CLR_RESET}"
    echo ""
    echo "Paste your SSH public key (usually from ~/.ssh/id_rsa.pub or ~/.ssh/id_ed25519.pub):"
    echo "Example: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... user@hostname"
    echo ""
    read -e -p "SSH Public Key: " SSH_PUBLIC_KEY

    while [[ -z "$SSH_PUBLIC_KEY" ]]; do
        echo -e "${CLR_RED}SSH public key is required for secure access!${CLR_RESET}"
        read -e -p "SSH Public Key: " SSH_PUBLIC_KEY
    done

    # Validate SSH key format
    if [[ ! "$SSH_PUBLIC_KEY" =~ ^ssh-(rsa|ed25519|ecdsa)[[:space:]] ]]; then
        echo -e "${CLR_YELLOW}Warning: SSH key format may be invalid. Continuing anyway...${CLR_RESET}"
    fi

    # Tailscale VPN Configuration (Optional)
    echo ""
    echo -e "${CLR_YELLOW}============================================${CLR_RESET}"
    echo -e "${CLR_YELLOW}  Tailscale VPN Configuration (Optional)${CLR_RESET}"
    echo -e "${CLR_YELLOW}============================================${CLR_RESET}"
    echo "Tailscale provides secure remote access to your Proxmox server."
    echo "You can get an auth key from: https://login.tailscale.com/admin/settings/keys"
    echo ""
    read -e -p "Install Tailscale? (y/n): " -i "y" INSTALL_TAILSCALE

    if [[ "$INSTALL_TAILSCALE" =~ ^[Yy]$ ]]; then
        INSTALL_TAILSCALE="yes"
        echo ""
        echo "Auth key is optional. If not provided, you'll need to authenticate manually after installation."
        echo "For unattended setup, use a reusable auth key (recommended: with tag and expiry)."
        echo ""
        read -e -p "Tailscale Auth Key (leave empty for manual auth): " TAILSCALE_AUTH_KEY

        if [[ -n "$TAILSCALE_AUTH_KEY" ]]; then
            echo -e "${CLR_GREEN}Auth key provided. Tailscale will be configured automatically.${CLR_RESET}"
        else
            echo -e "${CLR_YELLOW}No auth key provided. You'll need to run 'tailscale up' manually after reboot.${CLR_RESET}"
        fi

        # Tailscale features selection
        echo ""
        echo -e "${CLR_YELLOW}Tailscale Features:${CLR_RESET}"
        read -e -p "Enable Tailscale SSH? (y/n): " -i "y" TAILSCALE_SSH
        if [[ "$TAILSCALE_SSH" =~ ^[Yy]$ ]]; then
            TAILSCALE_SSH="yes"
        else
            TAILSCALE_SSH="no"
        fi

        read -e -p "Enable Proxmox Web UI via Tailscale Serve? (y/n): " -i "y" TAILSCALE_WEBUI
        if [[ "$TAILSCALE_WEBUI" =~ ^[Yy]$ ]]; then
            TAILSCALE_WEBUI="yes"
            echo -e "${CLR_GREEN}Proxmox Web UI will be accessible at https://HOSTNAME.your-tailnet.ts.net${CLR_RESET}"
        else
            TAILSCALE_WEBUI="no"
        fi
    else
        INSTALL_TAILSCALE="no"
        TAILSCALE_AUTH_KEY=""
        TAILSCALE_SSH="no"
        TAILSCALE_WEBUI="no"
        echo -e "${CLR_YELLOW}Tailscale installation skipped.${CLR_RESET}"
    fi
}


prepare_packages() {
    echo -e "${CLR_BLUE}Installing packages...${CLR_RESET}"
    echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" | tee /etc/apt/sources.list.d/pve.list

    if ! curl -fsSL -o /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg; then
        echo -e "${CLR_RED}Failed to download Proxmox GPG key! Exiting.${CLR_RESET}"
        exit 1
    fi

    if ! apt clean || ! apt update; then
        echo -e "${CLR_RED}Failed to update package lists! Exiting.${CLR_RESET}"
        exit 1
    fi

    if ! apt install -yq proxmox-auto-install-assistant xorriso ovmf wget sshpass; then
        echo -e "${CLR_RED}Failed to install required packages! Exiting.${CLR_RESET}"
        exit 1
    fi

    echo -e "${CLR_GREEN}Packages installed.${CLR_RESET}"
}

# Fetch latest Proxmox VE ISO
get_latest_proxmox_ve_iso() {
    local base_url="https://enterprise.proxmox.com/iso/"
    local latest_iso=$(curl -s "$base_url" | grep -oE 'proxmox-ve_[0-9]+\.[0-9]+-[0-9]+\.iso' | sort -V | tail -n1)

    if [[ -n "$latest_iso" ]]; then
        echo "${base_url}${latest_iso}"
    else
        echo "No Proxmox VE ISO found." >&2
        return 1
    fi
}

download_proxmox_iso() {
    if [[ -f "pve.iso" ]]; then
        echo -e "${CLR_YELLOW}Proxmox ISO file already exists, skipping download.${CLR_RESET}"
        return 0
    fi

    echo -e "${CLR_BLUE}Downloading Proxmox ISO...${CLR_RESET}"
    PROXMOX_ISO_URL=$(get_latest_proxmox_ve_iso)
    if [[ -z "$PROXMOX_ISO_URL" ]]; then
        echo -e "${CLR_RED}Failed to retrieve Proxmox ISO URL! Exiting.${CLR_RESET}"
        exit 1
    fi

    # Extract ISO filename and construct checksum URL
    ISO_FILENAME=$(basename "$PROXMOX_ISO_URL")
    CHECKSUM_URL="https://enterprise.proxmox.com/iso/SHA256SUMS"

    echo -e "${CLR_YELLOW}Downloading: $ISO_FILENAME${CLR_RESET}"

    if ! wget -O pve.iso "$PROXMOX_ISO_URL"; then
        echo -e "${CLR_RED}Failed to download Proxmox ISO! Exiting.${CLR_RESET}"
        exit 1
    fi

    if [[ ! -s "pve.iso" ]]; then
        echo -e "${CLR_RED}Downloaded ISO file is empty or corrupted! Exiting.${CLR_RESET}"
        rm -f pve.iso
        exit 1
    fi

    # Verify ISO checksum
    echo -e "${CLR_BLUE}Verifying ISO checksum...${CLR_RESET}"
    if wget -q -O SHA256SUMS "$CHECKSUM_URL"; then
        EXPECTED_CHECKSUM=$(grep "$ISO_FILENAME" SHA256SUMS | awk '{print $1}')
        if [[ -n "$EXPECTED_CHECKSUM" ]]; then
            ACTUAL_CHECKSUM=$(sha256sum pve.iso | awk '{print $1}')
            if [[ "$EXPECTED_CHECKSUM" == "$ACTUAL_CHECKSUM" ]]; then
                echo -e "${CLR_GREEN}ISO checksum verified successfully.${CLR_RESET}"
            else
                echo -e "${CLR_RED}ISO checksum verification FAILED!${CLR_RESET}"
                echo -e "${CLR_RED}Expected: $EXPECTED_CHECKSUM${CLR_RESET}"
                echo -e "${CLR_RED}Actual:   $ACTUAL_CHECKSUM${CLR_RESET}"
                rm -f pve.iso SHA256SUMS
                exit 1
            fi
        else
            echo -e "${CLR_YELLOW}Warning: Could not find checksum for $ISO_FILENAME, skipping verification.${CLR_RESET}"
        fi
        rm -f SHA256SUMS
    else
        echo -e "${CLR_YELLOW}Warning: Could not download checksum file, skipping verification.${CLR_RESET}"
    fi

    echo -e "${CLR_GREEN}Proxmox ISO downloaded.${CLR_RESET}"
}

make_answer_toml() {
    echo -e "${CLR_BLUE}Making answer.toml...${CLR_RESET}"

    # Build disk_list based on detected drives (using vda/vdb for QEMU virtio)
    if [ "$RAID_MODE" = "raid1" ]; then
        DISK_LIST='["/dev/vda", "/dev/vdb"]'
        ZFS_RAID="raid1"
    else
        DISK_LIST='["/dev/vda"]'
        ZFS_RAID="single"
    fi

    cat <<EOF > answer.toml
[global]
    keyboard = "en-us"
    country = "us"
    fqdn = "$FQDN"
    mailto = "$EMAIL"
    timezone = "$TIMEZONE"
    root_password = "$NEW_ROOT_PASSWORD"
    reboot_on_error = false

[network]
    source = "from-dhcp"

[disk-setup]
    filesystem = "zfs"
    zfs.raid = "$ZFS_RAID"
    disk_list = $DISK_LIST

EOF
    echo -e "${CLR_GREEN}answer.toml created (ZFS $ZFS_RAID mode).${CLR_RESET}"
}

make_autoinstall_iso() {
    echo -e "${CLR_BLUE}Making autoinstall.iso...${CLR_RESET}"
    proxmox-auto-install-assistant prepare-iso pve.iso --fetch-from iso --answer-file answer.toml --output pve-autoinstall.iso
    echo -e "${CLR_GREEN}pve-autoinstall.iso created.${CLR_RESET}"
}

is_uefi_mode() {
  [ -d /sys/firmware/efi ]
}

# Install Proxmox via QEMU/VNC
install_proxmox() {
    echo -e "${CLR_GREEN}Starting Proxmox VE installation...${CLR_RESET}"

    if is_uefi_mode; then
        UEFI_OPTS="-bios /usr/share/ovmf/OVMF.fd"
        echo -e "UEFI Supported! Booting with UEFI firmware."
    else
        UEFI_OPTS=""
        echo -e "UEFI Not Supported! Booting in legacy mode."
    fi

    # Detect available CPU cores and RAM for optimal QEMU performance
    AVAILABLE_CORES=$(nproc)
    AVAILABLE_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
    # Use half of available cores (min 2, max 16, but never exceed available)
    QEMU_CORES=$((AVAILABLE_CORES / 2))
    [ $QEMU_CORES -lt 2 ] && QEMU_CORES=2
    [ $QEMU_CORES -gt $AVAILABLE_CORES ] && QEMU_CORES=$AVAILABLE_CORES
    [ $QEMU_CORES -gt 16 ] && QEMU_CORES=16
    QEMU_RAM=8192
    [ $AVAILABLE_RAM_MB -lt 16384 ] && QEMU_RAM=4096

    echo -e "${CLR_YELLOW}Installing Proxmox VE (using $QEMU_CORES vCPUs, ${QEMU_RAM}MB RAM)${CLR_RESET}"
    echo -e "${CLR_YELLOW}=================================${CLR_RESET}"
    echo -e "${CLR_RED}Do NOT do anything, just wait about 5-10 min!${CLR_RESET}"
    echo -e "${CLR_YELLOW}=================================${CLR_RESET}"

    # Build QEMU drive arguments based on detected NVMe drives
    DRIVE_ARGS="-drive file=$NVME_DRIVE_1,format=raw,media=disk,if=virtio"
    if [ -n "$NVME_DRIVE_2" ]; then
        DRIVE_ARGS="$DRIVE_ARGS -drive file=$NVME_DRIVE_2,format=raw,media=disk,if=virtio"
    fi

    qemu-system-x86_64 \
        -enable-kvm $UEFI_OPTS \
        -cpu host -smp $QEMU_CORES -m $QEMU_RAM \
        -boot d -cdrom ./pve-autoinstall.iso \
        $DRIVE_ARGS -no-reboot -display none > /dev/null 2>&1
}

# Function to boot the installed Proxmox via QEMU with port forwarding
boot_proxmox_with_port_forwarding() {
    echo -e "${CLR_GREEN}Booting installed Proxmox with SSH port forwarding...${CLR_RESET}"

    if is_uefi_mode; then
        UEFI_OPTS="-bios /usr/share/ovmf/OVMF.fd"
        echo -e "${CLR_YELLOW}UEFI Supported! Booting with UEFI firmware.${CLR_RESET}"
    else
        UEFI_OPTS=""
        echo -e "${CLR_YELLOW}UEFI Not Supported! Booting in legacy mode.${CLR_RESET}"
    fi

    # Build QEMU drive arguments based on detected NVMe drives
    DRIVE_ARGS="-drive file=$NVME_DRIVE_1,format=raw,media=disk,if=virtio"
    if [ -n "$NVME_DRIVE_2" ]; then
        DRIVE_ARGS="$DRIVE_ARGS -drive file=$NVME_DRIVE_2,format=raw,media=disk,if=virtio"
    fi

    # Start QEMU in background with port forwarding
    nohup qemu-system-x86_64 -enable-kvm $UEFI_OPTS \
        -cpu host -device e1000,netdev=net0 \
        -netdev user,id=net0,hostfwd=tcp::5555-:22 \
        -smp $QEMU_CORES -m $QEMU_RAM \
        $DRIVE_ARGS -display none \
        > qemu_output.log 2>&1 &
    
    QEMU_PID=$!
    echo -e "${CLR_YELLOW}QEMU started with PID: $QEMU_PID${CLR_RESET}"
    
    # Wait for SSH to become available on port 5555
    echo -e "${CLR_YELLOW}Waiting for SSH to become available on port 5555...${CLR_RESET}"
    for i in {1..60}; do
        # Use bash built-in /dev/tcp instead of nc for better compatibility with Rescue System
        if (echo >/dev/tcp/localhost/5555) 2>/dev/null; then
            echo -e "${CLR_GREEN}SSH is available on port 5555.${CLR_RESET}"
            break
        fi
        echo -n "."
        sleep 5
        if [ $i -eq 60 ]; then
            echo -e "${CLR_RED}SSH is not available after 5 minutes. Check the system manually.${CLR_RESET}"
            return 1
        fi
    done
    
    return 0
}

make_template_files() {
    echo -e "${CLR_BLUE}Modifying template files...${CLR_RESET}"
    
    echo -e "${CLR_YELLOW}Downloading template files...${CLR_RESET}"
    mkdir -p ./template_files

    download_file "./template_files/99-proxmox.conf" "https://github.com/payk24/proxmox-hetzner/raw/refs/heads/main/files/template_files/99-proxmox.conf"
    download_file "./template_files/hosts" "https://github.com/payk24/proxmox-hetzner/raw/refs/heads/main/files/template_files/hosts"
    download_file "./template_files/interfaces" "https://github.com/payk24/proxmox-hetzner/raw/refs/heads/main/files/template_files/interfaces"
    download_file "./template_files/debian.sources" "https://github.com/payk24/proxmox-hetzner/raw/refs/heads/main/files/template_files/debian.sources"
    download_file "./template_files/proxmox.sources" "https://github.com/payk24/proxmox-hetzner/raw/refs/heads/main/files/template_files/proxmox.sources"

    # Security hardening templates
    download_file "./template_files/sshd_config" "https://github.com/payk24/proxmox-hetzner/raw/refs/heads/main/files/template_files/sshd_config"

    # Process hosts file
    echo -e "${CLR_YELLOW}Processing hosts file...${CLR_RESET}"
    sed -i "s|{{MAIN_IPV4}}|$MAIN_IPV4|g" ./template_files/hosts
    sed -i "s|{{FQDN}}|$FQDN|g" ./template_files/hosts
    sed -i "s|{{HOSTNAME}}|$HOSTNAME|g" ./template_files/hosts
    sed -i "s|{{MAIN_IPV6}}|$MAIN_IPV6|g" ./template_files/hosts

    # Process interfaces file
    echo -e "${CLR_YELLOW}Processing interfaces file...${CLR_RESET}"
    sed -i "s|{{INTERFACE_NAME}}|$INTERFACE_NAME|g" ./template_files/interfaces
    sed -i "s|{{MAIN_IPV4_CIDR}}|$MAIN_IPV4_CIDR|g" ./template_files/interfaces
    sed -i "s|{{MAIN_IPV4_GW}}|$MAIN_IPV4_GW|g" ./template_files/interfaces
    sed -i "s|{{MAC_ADDRESS}}|$MAC_ADDRESS|g" ./template_files/interfaces
    sed -i "s|{{IPV6_CIDR}}|$IPV6_CIDR|g" ./template_files/interfaces
    sed -i "s|{{PRIVATE_IP_CIDR}}|$PRIVATE_IP_CIDR|g" ./template_files/interfaces
    sed -i "s|{{PRIVATE_SUBNET}}|$PRIVATE_SUBNET|g" ./template_files/interfaces
    sed -i "s|{{FIRST_IPV6_CIDR}}|$FIRST_IPV6_CIDR|g" ./template_files/interfaces

    echo -e "${CLR_GREEN}Template files modified successfully.${CLR_RESET}"
}

# Function to configure the installed Proxmox via SSH
configure_proxmox_via_ssh() {
    echo -e "${CLR_BLUE}Starting post-installation configuration via SSH...${CLR_RESET}"
    make_template_files
	ssh-keygen -f "/root/.ssh/known_hosts" -R "[localhost]:5555" || true
    # copy template files to the server using scp
    sshpass -p "$NEW_ROOT_PASSWORD" scp -P 5555 -o StrictHostKeyChecking=no template_files/hosts root@localhost:/etc/hosts
    sshpass -p "$NEW_ROOT_PASSWORD" scp -P 5555 -o StrictHostKeyChecking=no template_files/interfaces root@localhost:/etc/network/interfaces
    sshpass -p "$NEW_ROOT_PASSWORD" scp -P 5555 -o StrictHostKeyChecking=no template_files/99-proxmox.conf root@localhost:/etc/sysctl.d/99-proxmox.conf
    sshpass -p "$NEW_ROOT_PASSWORD" scp -P 5555 -o StrictHostKeyChecking=no template_files/debian.sources root@localhost:/etc/apt/sources.list.d/debian.sources
    sshpass -p "$NEW_ROOT_PASSWORD" scp -P 5555 -o StrictHostKeyChecking=no template_files/proxmox.sources root@localhost:/etc/apt/sources.list.d/proxmox.sources
	
    # comment out the line in the sources.list file
    #sshpass -p "$NEW_ROOT_PASSWORD" ssh -p 5555 -o StrictHostKeyChecking=no root@localhost "sed -i 's/^\([^#].*\)/# \1/g' /etc/apt/sources.list.d/pve-enterprise.list"
    sshpass -p "$NEW_ROOT_PASSWORD" ssh -p 5555 -o StrictHostKeyChecking=no root@localhost "[ -f /etc/apt/sources.list ] && mv /etc/apt/sources.list /etc/apt/sources.list.bak"
    # Configure DNS servers
    sshpass -p "$NEW_ROOT_PASSWORD" ssh -p 5555 -o StrictHostKeyChecking=no root@localhost "echo -e 'nameserver 1.1.1.1\nnameserver 1.0.0.1\nnameserver 8.8.8.8\nnameserver 8.8.4.4' | tee /etc/resolv.conf"
    sshpass -p "$NEW_ROOT_PASSWORD" ssh -p 5555 -o StrictHostKeyChecking=no root@localhost "echo '$HOSTNAME' > /etc/hostname"
    sshpass -p "$NEW_ROOT_PASSWORD" ssh -p 5555 -o StrictHostKeyChecking=no root@localhost "systemctl disable --now rpcbind rpcbind.socket"

    # Configure ZFS ARC memory limits based on system RAM
    echo -e "${CLR_YELLOW}Configuring ZFS ARC memory limits...${CLR_RESET}"
    sshpass -p "$NEW_ROOT_PASSWORD" ssh -p 5555 -o StrictHostKeyChecking=no root@localhost 'bash -s' << 'ZFSEOF'
        # Get total RAM in bytes
        TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))

        # Calculate ARC limits (min: 1GB or 10% of RAM, max: 50% of RAM)
        if [ $TOTAL_RAM_GB -ge 128 ]; then
            ARC_MIN=$((16 * 1024 * 1024 * 1024))  # 16GB min for 128GB+ systems
            ARC_MAX=$((64 * 1024 * 1024 * 1024))  # 64GB max
        elif [ $TOTAL_RAM_GB -ge 64 ]; then
            ARC_MIN=$((8 * 1024 * 1024 * 1024))   # 8GB min
            ARC_MAX=$((32 * 1024 * 1024 * 1024))  # 32GB max
        elif [ $TOTAL_RAM_GB -ge 32 ]; then
            ARC_MIN=$((4 * 1024 * 1024 * 1024))   # 4GB min
            ARC_MAX=$((16 * 1024 * 1024 * 1024))  # 16GB max
        else
            ARC_MIN=$((1 * 1024 * 1024 * 1024))   # 1GB min
            ARC_MAX=$((TOTAL_RAM_KB * 1024 / 2))  # 50% of RAM max
        fi

        # Create ZFS configuration
        mkdir -p /etc/modprobe.d
        echo "options zfs zfs_arc_min=$ARC_MIN" > /etc/modprobe.d/zfs.conf
        echo "options zfs zfs_arc_max=$ARC_MAX" >> /etc/modprobe.d/zfs.conf

        echo "ZFS ARC configured: min=$(($ARC_MIN / 1024 / 1024 / 1024))GB, max=$(($ARC_MAX / 1024 / 1024 / 1024))GB"
ZFSEOF

    # Configure CPU governor for performance
    echo -e "${CLR_YELLOW}Configuring CPU governor...${CLR_RESET}"
    sshpass -p "$NEW_ROOT_PASSWORD" ssh -p 5555 -o StrictHostKeyChecking=no root@localhost 'bash -s' << 'CPUEOF'
        # Install cpufrequtils for CPU governor management
        apt-get update -qq && apt-get install -yqq cpufrequtils

        # Set performance governor
        echo 'GOVERNOR="performance"' > /etc/default/cpufrequtils

        # Apply immediately to all CPUs
        for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            echo "performance" > "$cpu" 2>/dev/null || true
        done

        echo "CPU governor set to performance"
CPUEOF

    # Deploy security configurations
    echo -e "${CLR_YELLOW}Deploying SSH hardening and security configurations...${CLR_RESET}"

    # Copy security files
    sshpass -p "$NEW_ROOT_PASSWORD" scp -P 5555 -o StrictHostKeyChecking=no template_files/sshd_config root@localhost:/etc/ssh/sshd_config

    # Deploy SSH public key
    echo -e "${CLR_YELLOW}Deploying SSH public key...${CLR_RESET}"
    sshpass -p "$NEW_ROOT_PASSWORD" ssh -p 5555 -o StrictHostKeyChecking=no root@localhost "mkdir -p /root/.ssh && chmod 700 /root/.ssh"
    sshpass -p "$NEW_ROOT_PASSWORD" ssh -p 5555 -o StrictHostKeyChecking=no root@localhost "echo '$SSH_PUBLIC_KEY' >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys"

    # Restart SSH to apply new configuration
    sshpass -p "$NEW_ROOT_PASSWORD" ssh -p 5555 -o StrictHostKeyChecking=no root@localhost "systemctl restart sshd"

    echo -e "${CLR_GREEN}Security hardening configured:${CLR_RESET}"
    echo "  - SSH: Key-only authentication, modern ciphers"
    echo "  - CPU governor: Performance mode"

    # Install Tailscale if requested
    if [[ "$INSTALL_TAILSCALE" == "yes" ]]; then
        echo -e "${CLR_YELLOW}Installing Tailscale VPN...${CLR_RESET}"
        sshpass -p "$NEW_ROOT_PASSWORD" ssh -p 5555 -o StrictHostKeyChecking=no root@localhost 'bash -s' << 'TAILSCALEEOF'
            # Add Tailscale repository and install
            curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
            curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list

            apt-get update -qq
            apt-get install -yqq tailscale

            # Enable and start tailscaled service
            systemctl enable tailscaled
            systemctl start tailscaled

            echo "Tailscale installed successfully"
TAILSCALEEOF

        # Build tailscale up command with selected options
        TAILSCALE_UP_CMD="tailscale up"
        if [[ -n "$TAILSCALE_AUTH_KEY" ]]; then
            TAILSCALE_UP_CMD="$TAILSCALE_UP_CMD --authkey='$TAILSCALE_AUTH_KEY'"
        fi
        if [[ "$TAILSCALE_SSH" == "yes" ]]; then
            TAILSCALE_UP_CMD="$TAILSCALE_UP_CMD --ssh"
        fi

        # If auth key is provided, authenticate Tailscale
        if [[ -n "$TAILSCALE_AUTH_KEY" ]]; then
            echo -e "${CLR_YELLOW}Authenticating Tailscale with provided auth key...${CLR_RESET}"
            sshpass -p "$NEW_ROOT_PASSWORD" ssh -p 5555 -o StrictHostKeyChecking=no root@localhost "$TAILSCALE_UP_CMD"

            # Get Tailscale IP and hostname for display
            TAILSCALE_IP=$(sshpass -p "$NEW_ROOT_PASSWORD" ssh -p 5555 -o StrictHostKeyChecking=no root@localhost "tailscale ip -4" 2>/dev/null || echo "pending")
            TAILSCALE_HOSTNAME=$(sshpass -p "$NEW_ROOT_PASSWORD" ssh -p 5555 -o StrictHostKeyChecking=no root@localhost "tailscale status --json | grep -o '\"DNSName\":\"[^\"]*\"' | head -1 | cut -d'\"' -f4 | sed 's/\\.$//' " 2>/dev/null || echo "")
            echo -e "${CLR_GREEN}Tailscale authenticated. IP: ${TAILSCALE_IP}${CLR_RESET}"

            # Configure Tailscale Serve for Proxmox Web UI if requested
            if [[ "$TAILSCALE_WEBUI" == "yes" ]]; then
                echo -e "${CLR_YELLOW}Configuring Tailscale Serve for Proxmox Web UI...${CLR_RESET}"
                sshpass -p "$NEW_ROOT_PASSWORD" ssh -p 5555 -o StrictHostKeyChecking=no root@localhost 'bash -s' << 'TAILSCALESERVEEOF'
                    # Configure tailscale serve to proxy HTTPS traffic to Proxmox Web UI
                    # Port 443 on Tailscale will forward to localhost:8006 (Proxmox)
                    tailscale serve --bg --https=443 https://127.0.0.1:8006

                    echo "Tailscale Serve configured for Proxmox Web UI"
TAILSCALESERVEEOF
                echo -e "${CLR_GREEN}Proxmox Web UI available via Tailscale Serve${CLR_RESET}"
            fi
        else
            TAILSCALE_IP="not authenticated"
            TAILSCALE_HOSTNAME=""
            echo -e "${CLR_YELLOW}Tailscale installed but not authenticated.${CLR_RESET}"
            echo -e "${CLR_YELLOW}Run 'tailscale up' after reboot to authenticate.${CLR_RESET}"
            if [[ "$TAILSCALE_WEBUI" == "yes" ]]; then
                echo -e "${CLR_YELLOW}Then run 'tailscale serve --bg --https=443 https://127.0.0.1:8006' to enable Web UI.${CLR_RESET}"
            fi
        fi
    fi

    # Power off the VM
    echo -e "${CLR_YELLOW}Powering off the VM...${CLR_RESET}"
    sshpass -p "$NEW_ROOT_PASSWORD" ssh -p 5555 -o StrictHostKeyChecking=no root@localhost 'poweroff' || true
    
    # Wait for QEMU to exit
    echo -e "${CLR_YELLOW}Waiting for QEMU process to exit...${CLR_RESET}"
    wait $QEMU_PID || true
    echo -e "${CLR_GREEN}QEMU process has exited.${CLR_RESET}"
}

# Function to reboot into the main OS
reboot_to_main_os() {
    echo -e "${CLR_GREEN}============================================${CLR_RESET}"
    echo -e "${CLR_GREEN}  Installation Complete!${CLR_RESET}"
    echo -e "${CLR_GREEN}============================================${CLR_RESET}"
    echo ""
    echo -e "${CLR_YELLOW}Security Configuration Summary:${CLR_RESET}"
    echo "  ✓ SSH public key deployed"
    echo "  ✓ Password authentication DISABLED"
    echo "  ✓ CPU governor set to performance"
    echo "  ✓ Kernel parameters optimized for virtualization"
    if [[ "$INSTALL_TAILSCALE" == "yes" ]]; then
        echo "  ✓ Tailscale VPN installed"
        if [[ -n "$TAILSCALE_AUTH_KEY" ]]; then
            echo "  ✓ Tailscale authenticated (IP: ${TAILSCALE_IP:-pending})"
        else
            echo "  ⚠ Tailscale needs authentication (run 'tailscale up' after reboot)"
        fi
        if [[ "$TAILSCALE_SSH" == "yes" ]]; then
            echo "  ✓ Tailscale SSH enabled"
        fi
        if [[ "$TAILSCALE_WEBUI" == "yes" ]]; then
            echo "  ✓ Tailscale Serve enabled for Proxmox Web UI"
        fi
    fi
    echo ""
    echo -e "${CLR_YELLOW}Access Information:${CLR_RESET}"
    echo "  Web UI:    https://${MAIN_IPV4_CIDR%/*}:8006"
    echo "  SSH:       ssh root@${MAIN_IPV4_CIDR%/*}"
    if [[ "$INSTALL_TAILSCALE" == "yes" && -n "$TAILSCALE_AUTH_KEY" && "$TAILSCALE_IP" != "pending" && "$TAILSCALE_IP" != "not authenticated" ]]; then
        if [[ "$TAILSCALE_SSH" == "yes" ]]; then
            echo "  Tailscale SSH: ssh root@${TAILSCALE_IP}"
        fi
        if [[ "$TAILSCALE_WEBUI" == "yes" ]]; then
            if [[ -n "$TAILSCALE_HOSTNAME" ]]; then
                echo "  Tailscale Web UI: https://${TAILSCALE_HOSTNAME}"
            else
                echo "  Tailscale Web UI: https://${TAILSCALE_IP}:8006"
            fi
        fi
    fi
    echo ""

    #ask user to reboot the system
    read -e -p "Do you want to reboot the system? (y/n): " -i "y" REBOOT
    if [[ "$REBOOT" == "y" ]]; then
        echo -e "${CLR_YELLOW}Rebooting the system...${CLR_RESET}"
        reboot
    else
        echo -e "${CLR_YELLOW}Exiting...${CLR_RESET}"
        exit 0
    fi
}



# Main execution flow
detect_nvme_drives
get_system_inputs
prepare_packages
download_proxmox_iso
make_answer_toml
make_autoinstall_iso
install_proxmox

echo -e "${CLR_YELLOW}Waiting for installation to complete...${CLR_RESET}"

# Boot the installed Proxmox with port forwarding
boot_proxmox_with_port_forwarding || {
    echo -e "${CLR_RED}Failed to boot Proxmox with port forwarding. Exiting.${CLR_RESET}"
    exit 1
}

# Configure Proxmox via SSH
configure_proxmox_via_ssh

# Reboot to the main OS
reboot_to_main_os
