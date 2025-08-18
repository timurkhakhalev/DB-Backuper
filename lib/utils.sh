#!/usr/bin/env bash
# Utility functions for db-backupper

# Logging functions
log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

log_warning() {
    echo "[WARNING] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

# Check for required commands
check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "Command '$1' not found. Please install it and ensure it's in your PATH."
        exit 1
    fi
}

# Set up robust PATH for cron environments
setup_path() {
    # Add common binary paths that might not be available in cron
    export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin:$PATH"
    
    # Add user's local bin if it exists
    if [[ -d "$HOME/.local/bin" ]]; then
        export PATH="$HOME/.local/bin:$PATH"
    fi
    
    # Add snap bin if it exists (common on Ubuntu)
    if [[ -d "/snap/bin" ]]; then
        export PATH="/snap/bin:$PATH"
    fi
}

# Check all required commands
check_all_commands() {
    check_command "aws"
    check_command "docker"
    check_command "tar"
    check_command "find"
    check_command "sed"
    check_command "tr"
    # pg_dump and psql are run inside docker, so not checked on host
}

# Find the script directory (works even when installed globally)
get_script_dir() {
    local source="${BASH_SOURCE[0]}"
    while [[ -h "$source" ]]; do # resolve $source until the file is no longer a symlink
        local dir="$(cd -P "$(dirname "$source")" && pwd)"
        source="$(readlink "$source")"
        [[ $source != /* ]] && source="$dir/$source" # if $source was a relative symlink, we need to resolve it relative to the path where the symlink file was located
    done
    local dir="$(cd -P "$(dirname "$source")" && pwd)"
    
    # If we're installed globally, look for config in common locations
    if [[ "$dir" == "/usr/local/bin" ]] || [[ "$dir" == "/usr/bin" ]]; then
        # Look for config in current directory first, then user's home
        if [[ -f "./backup.conf" ]]; then
            echo "$(pwd)"
        elif [[ -f "$HOME/.config/db-backupper/backup.conf" ]]; then
            echo "$HOME/.config/db-backupper"
        elif [[ -f "/etc/db-backupper/backup.conf" ]]; then
            echo "/etc/db-backupper"
        else
            echo "$(pwd)"
        fi
    else
        # We're running from the source directory
        echo "$dir/.."
    fi
}

# Check available disk space (in bytes)
check_disk_space() {
    local required_bytes="$1"
    local target_dir="${2:-/tmp}"
    
    local available_bytes
    available_bytes=$(df "$target_dir" | awk 'NR==2 {print $4}')
    available_bytes=$((available_bytes * 1024)) # Convert KB to bytes
    
    if [[ $available_bytes -lt $required_bytes ]]; then
        log_error "Insufficient disk space. Required: $(numfmt --to=iec $required_bytes), Available: $(numfmt --to=iec $available_bytes)"
        return 1
    fi
    
    log_info "Disk space check passed. Available: $(numfmt --to=iec $available_bytes)"
    return 0
}

# Get current memory usage in MB
get_memory_usage() {
    local pid="${1:-$$}"
    local mem_kb
    mem_kb=$(ps -o rss= -p "$pid" 2>/dev/null || echo "0")
    echo $((mem_kb / 1024))
}

# Check if memory usage is within limits
check_memory_limit() {
    local max_memory_mb="$1"
    local current_memory_mb
    current_memory_mb=$(get_memory_usage)
    
    if [[ $current_memory_mb -gt $max_memory_mb ]]; then
        log_error "Memory limit exceeded: ${current_memory_mb}MB > ${max_memory_mb}MB"
        return 1
    fi
    
    return 0
}

# Execute command with timeout
execute_with_timeout() {
    local timeout_seconds="$1"
    local description="$2"
    shift 2
    local cmd=("$@")
    
    log_info "Starting $description (timeout: ${timeout_seconds}s)"
    
    # Start command in background
    "${cmd[@]}" &
    local cmd_pid=$!
    
    # Start timeout monitor
    (
        sleep "$timeout_seconds"
        if kill -0 "$cmd_pid" 2>/dev/null; then
            log_error "$description timed out after ${timeout_seconds}s"
            kill -TERM "$cmd_pid" 2>/dev/null
            sleep 5
            kill -KILL "$cmd_pid" 2>/dev/null
        fi
    ) &
    local timeout_pid=$!
    
    # Wait for command completion
    local exit_code=0
    wait "$cmd_pid" || exit_code=$?
    
    # Clean up timeout monitor
    kill "$timeout_pid" 2>/dev/null || true
    wait "$timeout_pid" 2>/dev/null || true
    
    return $exit_code
}