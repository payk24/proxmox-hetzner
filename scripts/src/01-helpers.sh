# =============================================================================
# Helper functions
# =============================================================================

# Table drawing constants
TABLE_WIDTH=55
TABLE_COL1=17
TABLE_COL2=35

# Draw table border
table_top() {
    echo -e "${CLR_BLUE}┌$(printf '─%.0s' $(seq 1 $TABLE_WIDTH))┐${CLR_RESET}"
}

table_bottom() {
    echo -e "${CLR_BLUE}└$(printf '─%.0s' $(seq 1 $TABLE_WIDTH))┘${CLR_RESET}"
}

table_separator() {
    echo -e "${CLR_BLUE}├$(printf '─%.0s' $(seq 1 $TABLE_WIDTH))┤${CLR_RESET}"
}

table_separator_cols() {
    echo -e "${CLR_BLUE}├$(printf '─%.0s' $(seq 1 $TABLE_COL1))┬$(printf '─%.0s' $(seq 1 $TABLE_COL2))┤${CLR_RESET}"
}

table_separator_cols_end() {
    echo -e "${CLR_BLUE}├$(printf '─%.0s' $(seq 1 $TABLE_COL1))┴$(printf '─%.0s' $(seq 1 $TABLE_COL2))┤${CLR_RESET}"
}

# Table header (full width)
table_header() {
    local title="$1"
    printf "${CLR_BLUE}│${CLR_RESET} ${CLR_CYAN}%-$((TABLE_WIDTH-2))s${CLR_RESET} ${CLR_BLUE}│${CLR_RESET}\n" "$title"
}

# Table row with two columns
table_row() {
    local col1="$1"
    local col2="$2"
    local color="${3:-${CLR_RESET}}"
    printf "${CLR_BLUE}│${CLR_RESET} %-$((TABLE_COL1-2))s ${CLR_BLUE}│${CLR_RESET} ${color}%-$((TABLE_COL2-2))s${CLR_RESET} ${CLR_BLUE}│${CLR_RESET}\n" "$col1" "$col2"
}

# Table row full width
table_row_full() {
    local text="$1"
    local color="${2:-${CLR_RESET}}"
    printf "${CLR_BLUE}│${CLR_RESET} ${color}%-$((TABLE_WIDTH-2))s${CLR_RESET} ${CLR_BLUE}│${CLR_RESET}\n" "$text"
}

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

# SSH helper functions to reduce duplication
SSH_OPTS="-o StrictHostKeyChecking=no"
SSH_PORT="5555"

remote_exec() {
    sshpass -p "$NEW_ROOT_PASSWORD" ssh -p "$SSH_PORT" $SSH_OPTS root@localhost "$@"
}

remote_exec_script() {
    sshpass -p "$NEW_ROOT_PASSWORD" ssh -p "$SSH_PORT" $SSH_OPTS root@localhost 'bash -s'
}

# Execute remote script with progress indicator (hides output, shows spinner)
remote_exec_with_progress() {
    local message="$1"
    local script="$2"

    echo "$script" | sshpass -p "$NEW_ROOT_PASSWORD" ssh -p "$SSH_PORT" $SSH_OPTS root@localhost 'bash -s' > /dev/null 2>&1 &
    local pid=$!
    show_progress $pid "$message"
    wait $pid
    return $?
}

remote_copy() {
    local src="$1"
    local dst="$2"
    sshpass -p "$NEW_ROOT_PASSWORD" scp -P "$SSH_PORT" $SSH_OPTS "$src" "root@localhost:$dst"
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
        echo -e "${CLR_RED}${error_msg}${CLR_RESET}"
    done
}

# Progress indicator with spinner and elapsed time
show_progress() {
    local pid=$1
    local message="${2:-Processing}"
    local spinner='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local start_time=$(date +%s)
    local i=0

    while kill -0 "$pid" 2>/dev/null; do
        local elapsed=$(($(date +%s) - start_time))
        local mins=$((elapsed / 60))
        local secs=$((elapsed % 60))
        printf "\r${CLR_YELLOW}${spinner:i++%${#spinner}:1} %s [%02d:%02d]${CLR_RESET}" "$message" "$mins" "$secs"
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
    local spinner='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
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

        printf "\r${CLR_YELLOW}${spinner:i++%${#spinner}:1} %s [%02d:%02d]${CLR_RESET}" "$message" "$mins" "$secs"
        sleep "$interval"
    done
}
