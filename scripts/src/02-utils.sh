# =============================================================================
# General utilities
# =============================================================================

# Download files with retry
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
                print_error "Downloaded file is empty: $output_file"
            fi
        else
            print_warning "Download failed (attempt $((retry_count + 1))/$max_retries): $url"
        fi
        retry_count=$((retry_count + 1))
        [ $retry_count -lt $max_retries ] && sleep 2
    done

    print_error "Failed to download $url after $max_retries attempts. Exiting."
    exit 1
}

# Function to read password with asterisks shown for each character
read_password() {
    local prompt="$1"
    local password=""
    local char=""

    # Output prompt to stderr so it's visible when stdout is captured
    echo -n "$prompt" >&2

    while IFS= read -r -s -n1 char; do
        if [[ -z "$char" ]]; then
            break
        fi
        if [[ "$char" == $'\x7f' || "$char" == $'\x08' ]]; then
            if [[ -n "$password" ]]; then
                password="${password%?}"
                echo -ne "\b \b" >&2
            fi
        else
            password+="$char"
            echo -n "*" >&2
        fi
    done

    # Newline to stderr for display
    echo "" >&2
    # Password to stdout for capture
    echo "$password"
}

# Prompt with validation loop
prompt_validated() {
    local prompt="$1"
    local default="$2"
    local validator="$3"
    local error_msg="$4"
    local result=""

    while true; do
        read -e -p "$prompt" -i "$default" result
        if $validator "$result"; then
            echo "$result"
            return 0
        fi
        print_error "$error_msg"
    done
}

# =============================================================================
# Progress indicators
# =============================================================================

# Spinner characters for progress display
SPINNER_CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

# Progress indicator with spinner and elapsed time
show_progress() {
    local pid=$1
    local message="${2:-Processing}"
    local start_time=$(date +%s)
    local i=0

    while kill -0 "$pid" 2>/dev/null; do
        local elapsed=$(($(date +%s) - start_time))
        local mins=$((elapsed / 60))
        local secs=$((elapsed % 60))
        printf "\r${CLR_YELLOW}${SPINNER_CHARS:i++%${#SPINNER_CHARS}:1} %s [%02d:%02d]${CLR_RESET}" "$message" "$mins" "$secs"
        sleep 0.2
    done

    local total=$(($(date +%s) - start_time))
    local mins=$((total / 60))
    local secs=$((total % 60))
    printf "\r${CLR_GREEN}✓ %s completed [%02d:%02d]${CLR_RESET}\n" "$message" "$mins" "$secs"
}

# Wait for condition with progress
wait_with_progress() {
    local message="$1"
    local timeout="$2"
    local check_cmd="$3"
    local interval="${4:-5}"
    local start_time=$(date +%s)
    local i=0

    while true; do
        local elapsed=$(($(date +%s) - start_time))
        local mins=$((elapsed / 60))
        local secs=$((elapsed % 60))

        if eval "$check_cmd" 2>/dev/null; then
            printf "\r${CLR_GREEN}✓ %s [%02d:%02d]${CLR_RESET}\n" "$message" "$mins" "$secs"
            return 0
        fi

        if [ $elapsed -ge $timeout ]; then
            printf "\r${CLR_RED}✗ %s timed out [%02d:%02d]${CLR_RESET}\n" "$message" "$mins" "$secs"
            return 1
        fi

        printf "\r${CLR_YELLOW}${SPINNER_CHARS:i++%${#SPINNER_CHARS}:1} %s [%02d:%02d]${CLR_RESET}" "$message" "$mins" "$secs"
        sleep "$interval"
    done
}

# Format time duration
format_duration() {
    local seconds="$1"
    local hours=$((seconds / 3600))
    local minutes=$(((seconds % 3600) / 60))
    local secs=$((seconds % 60))

    if [[ $hours -gt 0 ]]; then
        echo "${hours}h ${minutes}m ${secs}s"
    else
        echo "${minutes}m ${secs}s"
    fi
}
