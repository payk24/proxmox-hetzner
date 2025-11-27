# =============================================================================
# Base system configuration
# =============================================================================

make_template_files() {
    print_info "Modifying template files..."

    print_info "Downloading template files..."
    mkdir -p ./template_files

    download_file "./template_files/99-proxmox.conf" "https://github.com/payk24/proxmox-hetzner/raw/refs/heads/main/template_files/99-proxmox.conf"
    download_file "./template_files/hosts" "https://github.com/payk24/proxmox-hetzner/raw/refs/heads/main/template_files/hosts"
    download_file "./template_files/debian.sources" "https://github.com/payk24/proxmox-hetzner/raw/refs/heads/main/template_files/debian.sources"
    download_file "./template_files/proxmox.sources" "https://github.com/payk24/proxmox-hetzner/raw/refs/heads/main/template_files/proxmox.sources"

    # Security hardening templates
    download_file "./template_files/sshd_config" "https://github.com/payk24/proxmox-hetzner/raw/refs/heads/main/template_files/sshd_config"

    # Download interfaces template based on bridge mode
    local interfaces_template="interfaces.${BRIDGE_MODE:-internal}"
    download_file "./template_files/interfaces" "https://github.com/payk24/proxmox-hetzner/raw/refs/heads/main/template_files/${interfaces_template}"

    # Process hosts file
    print_info "Processing hosts file..."
    sed -i "s|{{MAIN_IPV4}}|$MAIN_IPV4|g" ./template_files/hosts
    sed -i "s|{{FQDN}}|$FQDN|g" ./template_files/hosts
    sed -i "s|{{HOSTNAME}}|$PVE_HOSTNAME|g" ./template_files/hosts
    sed -i "s|{{MAIN_IPV6}}|$MAIN_IPV6|g" ./template_files/hosts

    # Process interfaces file
    print_info "Processing interfaces file (mode: ${BRIDGE_MODE:-internal})..."
    sed -i "s|{{INTERFACE_NAME}}|$INTERFACE_NAME|g" ./template_files/interfaces
    sed -i "s|{{MAIN_IPV4}}|$MAIN_IPV4|g" ./template_files/interfaces
    sed -i "s|{{MAIN_IPV4_GW}}|$MAIN_IPV4_GW|g" ./template_files/interfaces
    sed -i "s|{{MAIN_IPV6}}|$MAIN_IPV6|g" ./template_files/interfaces
    sed -i "s|{{PRIVATE_IP_CIDR}}|$PRIVATE_IP_CIDR|g" ./template_files/interfaces
    sed -i "s|{{PRIVATE_SUBNET}}|$PRIVATE_SUBNET|g" ./template_files/interfaces
    sed -i "s|{{FIRST_IPV6_CIDR}}|$FIRST_IPV6_CIDR|g" ./template_files/interfaces

    print_success "Template files modified"
}

# Configure base system via SSH
configure_base_system() {
    print_info "Starting base system configuration via SSH..."
    make_template_files
    ssh-keygen -f "/root/.ssh/known_hosts" -R "[localhost]:5555" || true

    # Copy template files
    remote_copy "template_files/hosts" "/etc/hosts"
    remote_copy "template_files/interfaces" "/etc/network/interfaces"
    remote_copy "template_files/99-proxmox.conf" "/etc/sysctl.d/99-proxmox.conf"
    remote_copy "template_files/debian.sources" "/etc/apt/sources.list.d/debian.sources"
    remote_copy "template_files/proxmox.sources" "/etc/apt/sources.list.d/proxmox.sources"

    # Basic system configuration
    remote_exec "[ -f /etc/apt/sources.list ] && mv /etc/apt/sources.list /etc/apt/sources.list.bak"
    remote_exec "echo -e 'nameserver 1.1.1.1\nnameserver 1.0.0.1\nnameserver 8.8.8.8\nnameserver 8.8.4.4' > /etc/resolv.conf"
    remote_exec "echo '$PVE_HOSTNAME' > /etc/hostname"
    remote_exec "systemctl disable --now rpcbind rpcbind.socket"

    # Configure ZFS ARC memory limits
    print_info "Configuring ZFS ARC memory limits..."
    remote_exec_script << 'ZFSEOF'
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

    # Disable enterprise repositories
    print_info "Disabling enterprise repositories..."
    remote_exec_script << 'REPOEOF'
        # Disable ALL enterprise repositories (PVE, Ceph, Ceph-Squid, etc.)
        for repo_file in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
            [ -f "$repo_file" ] || continue
            if grep -q "enterprise.proxmox.com" "$repo_file" 2>/dev/null; then
                mv "$repo_file" "${repo_file}.disabled"
                echo "Disabled $(basename "$repo_file")"
            fi
        done

        # Also check and disable any enterprise sources in main sources.list
        if [ -f /etc/apt/sources.list ] && grep -q "enterprise.proxmox.com" /etc/apt/sources.list 2>/dev/null; then
            sed -i 's|^deb.*enterprise.proxmox.com|# &|g' /etc/apt/sources.list
            echo "Commented out enterprise repos in sources.list"
        fi
REPOEOF

    # Update all system packages
    remote_exec_with_progress "Updating system packages" '
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get dist-upgrade -yqq
        apt-get autoremove -yqq
        apt-get clean
        pveupgrade 2>/dev/null || true
        pveam update 2>/dev/null || true
    '

    # Install monitoring and system utilities
    remote_exec_with_progress "Installing monitoring utilities" '
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -yqq btop iotop ncdu tmux pigz smartmontools jq bat 2>/dev/null || {
            for pkg in btop iotop ncdu tmux pigz smartmontools jq bat; do
                apt-get install -yqq "$pkg" 2>/dev/null || true
            done
        }
        apt-get install -yqq libguestfs-tools 2>/dev/null || true
    '

    # Install and configure zsh as default shell
    print_info "Installing and configuring zsh..."
    remote_exec_script << 'ZSHEOF'
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -yqq zsh zsh-autosuggestions zsh-syntax-highlighting

        # Create minimal .zshrc for root
        cat > /root/.zshrc << 'ZSHRC'
# Proxmox ZSH Configuration

# History settings
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_SPACE
setopt SHARE_HISTORY
setopt APPEND_HISTORY

# Key bindings
bindkey -e
bindkey '^[[A' history-search-backward
bindkey '^[[B' history-search-forward
bindkey '^[[H' beginning-of-line
bindkey '^[[F' end-of-line
bindkey '^[[3~' delete-char

# Completion
autoload -Uz compinit && compinit
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'

# Colors
autoload -Uz colors && colors

# Prompt with git branch support
autoload -Uz vcs_info
precmd() { vcs_info }
zstyle ':vcs_info:git:*' formats ' (%b)'
setopt PROMPT_SUBST
PROMPT='%F{cyan}%n@%m%f:%F{blue}%~%f%F{yellow}${vcs_info_msg_0_}%f %# '

# Aliases
alias ll='ls -lah --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'
alias grep='grep --color=auto'
alias df='df -h'
alias du='du -h'
alias free='free -h'
alias ..='cd ..'
alias ...='cd ../..'

# Proxmox aliases
alias qml='qm list'
alias pctl='pct list'
alias pvesh='pvesh'
alias zpl='zpool list'
alias zst='zpool status'

# Use bat instead of cat if available
command -v bat &>/dev/null && alias cat='bat --paging=never'

# Use btop instead of top if available
command -v btop &>/dev/null && alias top='btop'

# Load plugins if available
[ -f /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ] && \
    source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
[ -f /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ] && \
    source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

# Auto-suggestions color (gray)
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=8'
ZSHRC

        # Set zsh as default shell for root
        chsh -s /bin/zsh root

        echo "ZSH installed and configured as default shell"
ZSHEOF
    print_success "ZSH configured as default shell"

    # Configure UTF-8 locales
    remote_exec_with_progress "Configuring UTF-8 locales" '
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -yqq locales
        sed -i "s/# en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen
        sed -i "s/# ru_RU.UTF-8/ru_RU.UTF-8/" /etc/locale.gen
        locale-gen
        update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
    '

    # Configure CPU governor
    remote_exec_with_progress "Configuring CPU governor" '
        apt-get update -qq && apt-get install -yqq cpufrequtils 2>/dev/null || true
        echo "GOVERNOR=\"performance\"" > /etc/default/cpufrequtils
        if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
            for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
                [ -f "$cpu" ] && echo "performance" > "$cpu" 2>/dev/null || true
            done
        fi
    '

    # Remove Proxmox subscription notice
    print_info "Removing Proxmox subscription notice..."
    remote_exec_script << 'SUBEOF'
        if [ -f /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js ]; then
            sed -Ezi.bak "s/(Ext.Msg.show\(\{\s+title: gettext\('No valid sub)/void\(\{ \/\/\1/g" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
            systemctl restart pveproxy.service
            echo "Subscription notice removed"
        else
            echo "proxmoxlib.js not found, skipping"
        fi
SUBEOF

    print_success "Base system configuration complete"
}
