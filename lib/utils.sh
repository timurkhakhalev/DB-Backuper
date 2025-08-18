#!/usr/bin/env bash
# Utility functions for db-backupper

# Logging functions
log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
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