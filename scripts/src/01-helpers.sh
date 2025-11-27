# =============================================================================
# Helper functions
# =============================================================================

# Display a boxed section with title using 'boxes'
# Usage: display_box "title" "content"
display_box() {
    local title="$1"
    local content="$2"
    local box_style="${3:-stone}"

    echo -e "${CLR_BLUE}"
    {
        echo "$title"
        echo ""
        echo "$content"
    } | boxes -d "$box_style" -p a1
    echo -e "${CLR_RESET}"
}

# Display system info table using boxes and column
# Takes associative array-like pairs: "label|value|status"
# status: ok=green, warn=yellow, error=red
display_info_table() {
    local title="$1"
    shift
    local items=("$@")

    local content=""
    for item in "${items[@]}"; do
        local label="${item%%|*}"
        local rest="${item#*|}"
        local value="${rest%%|*}"
        local status="${rest#*|}"

        case "$status" in
            ok)    content+="[OK]     $label: $value"$'\n' ;;
            warn)  content+="[WARN]   $label: $value"$'\n' ;;
            error) content+="[ERROR]  $label: $value"$'\n' ;;
            *)     content+="         $label: $value"$'\n' ;;
        esac
    done

    # Remove trailing newline and display
    content="${content%$'\n'}"

    echo ""
    {
        echo "=== $title ==="
        echo ""
        echo "$content"
    } | boxes -d stone -p a1
    echo ""
}

# Colorize the output of boxes (post-process)
colorize_status() {
    local green=$'\033[1;32m'
    local yellow=$'\033[1;33m'
    local red=$'\033[1;31m'
    local reset=$'\033[m'

    sed -e "s/\[OK\]/${green}[OK]${reset}/g" \
        -e "s/\[WARN\]/${yellow}[WARN]${reset}/g" \
        -e "s/\[ERROR\]/${red}[ERROR]${reset}/g"
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

# =============================================================================
# Interactive menu selection
# =============================================================================
# Usage: interactive_menu "Title" "header_content" "label1|desc1" "label2|desc2" ...
# Sets: MENU_SELECTED (0-based index of selected option)
# Fixed width: 70 characters for consistent appearance
MENU_BOX_WIDTH=70

interactive_menu() {
    local title="$1"
    local header="$2"
    shift 2
    local items=("$@")

    local -a labels=()
    local -a descriptions=()

    # Parse items into labels and descriptions
    for item in "${items[@]}"; do
        labels+=("${item%%|*}")
        descriptions+=("${item#*|}")
    done

    local selected=0
    local key=""
    local box_lines=0
    local num_options=${#labels[@]}

    # Function to draw the menu box with fixed width
    _draw_menu() {
        local content=""

        # Add header content if provided
        if [[ -n "$header" ]]; then
            content+="$header"$'\n'
            content+=""$'\n'
        fi

        # Add options
        for i in "${!labels[@]}"; do
            if [ $i -eq $selected ]; then
                content+="[*] ${labels[$i]}"$'\n'
                content+="    └─ ${descriptions[$i]}"$'\n'
            else
                content+="[ ] ${labels[$i]}"$'\n'
                content+="    └─ ${descriptions[$i]}"$'\n'
            fi
        done

        # Remove trailing newline
        content="${content%$'\n'}"

        {
            echo "$title"
            echo "$content"
        } | boxes -d stone -p a1 -s $MENU_BOX_WIDTH
    }

    # Hide cursor
    tput civis

    # Calculate box height
    box_lines=$(_draw_menu | wc -l)

    # Draw initial menu
    _draw_menu | sed -e $'s/\\[\\*\\]/\033[1;32m[●]\033[m/g' \
                     -e $'s/\\[ \\]/\033[1;34m[○]\033[m/g'

    while true; do
        # Read a single keypress
        IFS= read -rsn1 key

        # Check for escape sequence (arrow keys)
        if [[ "$key" == $'\x1b' ]]; then
            read -rsn2 -t 0.1 key || true
            case "$key" in
                '[A') # Up arrow
                    ((selected--)) || true
                    [ $selected -lt 0 ] && selected=$((num_options - 1))
                    ;;
                '[B') # Down arrow
                    ((selected++)) || true
                    [ $selected -ge $num_options ] && selected=0
                    ;;
            esac
        elif [[ "$key" == "" ]]; then
            # Enter pressed - confirm selection
            break
        elif [[ "$key" =~ ^[1-9]$ ]] && [ "$key" -le "$num_options" ]; then
            # Number key pressed
            selected=$((key - 1))
            break
        fi

        # Move cursor up to redraw menu (fixes scroll issue)
        tput cuu $box_lines

        # Clear lines and redraw
        for ((i=0; i<box_lines; i++)); do
            printf "\033[2K\n"
        done
        tput cuu $box_lines

        # Draw the menu with colors
        _draw_menu | sed -e $'s/\\[\\*\\]/\033[1;32m[●]\033[m/g' \
                         -e $'s/\\[ \\]/\033[1;34m[○]\033[m/g'
    done

    # Show cursor again
    tput cnorm

    # Clear the menu box
    tput cuu $box_lines
    for ((i=0; i<box_lines; i++)); do
        printf "\033[2K\n"
    done
    tput cuu $box_lines

    # Set result
    MENU_SELECTED=$selected
}
