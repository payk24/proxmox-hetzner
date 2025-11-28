# =============================================================================
# SSH helper functions
# =============================================================================

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"
SSH_PORT="5555"

# Wait for SSH to be fully ready (not just TCP port open)
# This performs an actual SSH connection test, not just a TCP check
# Shows spinner for user feedback
wait_for_ssh_ready() {
    local max_attempts="${1:-60}"
    local message="${2:-Connecting to VM via SSH}"
    local done_message="${3:-SSH connection established}"
    local attempt=1
    local i=0

    log "Waiting for SSH to be fully ready (max $max_attempts attempts)"

    while [[ $attempt -le $max_attempts ]]; do
        # Show spinner
        printf "\r${CLR_YELLOW}${SPINNER_CHARS:i++%${#SPINNER_CHARS}:1} %s${CLR_RESET}" "$message"

        if sshpass -p "$NEW_ROOT_PASSWORD" ssh -p "$SSH_PORT" $SSH_OPTS root@localhost "exit 0" 2>/dev/null; then
            printf "\r\e[K${CLR_GREEN}✓ %s${CLR_RESET}\n" "$done_message"
            log "SSH is fully ready after $attempt attempt(s)"
            return 0
        fi

        log "SSH not ready yet (attempt $attempt/$max_attempts)"
        sleep 2
        ((attempt++))
    done

    printf "\r\e[K${CLR_RED}✗ SSH connection failed after $max_attempts attempts${CLR_RESET}\n"
    log "ERROR: SSH failed to become ready after $max_attempts attempts"
    return 1
}

remote_exec() {
    log "remote_exec: $*"
    sshpass -p "$NEW_ROOT_PASSWORD" ssh -p "$SSH_PORT" $SSH_OPTS root@localhost "$@"
}

remote_exec_script() {
    sshpass -p "$NEW_ROOT_PASSWORD" ssh -p "$SSH_PORT" $SSH_OPTS root@localhost 'bash -s'
}

# Execute remote script with progress indicator (hides output, shows spinner)
remote_exec_with_progress() {
    local message="$1"
    local script="$2"
    local done_message="${3:-$message}"

    log "remote_exec_with_progress: $message"
    echo "$script" | sshpass -p "$NEW_ROOT_PASSWORD" ssh -p "$SSH_PORT" $SSH_OPTS root@localhost 'bash -s' > /dev/null 2>&1 &
    local pid=$!
    show_progress $pid "$message" "$done_message"
    wait $pid
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log "remote_exec_with_progress FAILED: $message (exit code: $exit_code)"
    fi
    return $exit_code
}

remote_copy() {
    local src="$1"
    local dst="$2"
    local max_retries=3
    local attempt=1
    local delay=2

    log "remote_copy: $src -> $dst"

    while [[ $attempt -le $max_retries ]]; do
        if sshpass -p "$NEW_ROOT_PASSWORD" scp -P "$SSH_PORT" $SSH_OPTS "$src" "root@localhost:$dst" 2>/dev/null; then
            return 0
        fi

        if [[ $attempt -lt $max_retries ]]; then
            log "remote_copy failed (attempt $attempt/$max_retries), retrying in ${delay}s..."
            sleep $delay
            delay=$((delay * 2))
        fi
        ((attempt++))
    done

    log "ERROR: remote_copy failed after $max_retries attempts: $src -> $dst"
    return 1
}

# =============================================================================
# SSH key utilities
# =============================================================================

# Parse SSH public key into components
# Sets: SSH_KEY_TYPE, SSH_KEY_DATA, SSH_KEY_COMMENT, SSH_KEY_SHORT
parse_ssh_key() {
    local key="$1"

    # Reset variables
    SSH_KEY_TYPE=""
    SSH_KEY_DATA=""
    SSH_KEY_COMMENT=""
    SSH_KEY_SHORT=""

    if [[ -z "$key" ]]; then
        return 1
    fi

    # Parse: type base64data [comment]
    SSH_KEY_TYPE=$(echo "$key" | awk '{print $1}')
    SSH_KEY_DATA=$(echo "$key" | awk '{print $2}')
    SSH_KEY_COMMENT=$(echo "$key" | awk '{$1=""; $2=""; print}' | sed 's/^ *//')

    # Create shortened version of key data (first 20 + last 10 chars)
    if [[ ${#SSH_KEY_DATA} -gt 35 ]]; then
        SSH_KEY_SHORT="${SSH_KEY_DATA:0:20}...${SSH_KEY_DATA: -10}"
    else
        SSH_KEY_SHORT="$SSH_KEY_DATA"
    fi

    return 0
}

# Validate SSH public key format
validate_ssh_key() {
    local key="$1"
    [[ "$key" =~ ^ssh-(rsa|ed25519|ecdsa)[[:space:]] ]]
}

# Get SSH key from rescue system authorized_keys
get_rescue_ssh_key() {
    if [[ -f /root/.ssh/authorized_keys ]]; then
        grep -E "^ssh-(rsa|ed25519|ecdsa)" /root/.ssh/authorized_keys 2>/dev/null | head -1
    fi
}
