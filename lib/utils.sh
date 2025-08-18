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
        local dir="$(cd -P "$(dirname "$source")" && pwd 2>&1)"
        source="$(readlink "$source" 2>&1)"
        [[ $source != /* ]] && source="$dir/$source" # if $source was a relative symlink, we need to resolve it relative to the path where the symlink file was located
    done
    local dir="$(cd -P "$(dirname "$source")" && pwd 2>&1)"
    
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

# Generate crontab examples for automated backups
action_crontab() {
    local script_path
    local log_dir
    local db_name_safe
    
    # Determine the script path
    if command -v db-backupper &> /dev/null && [[ "$(command -v db-backupper)" != *"$(pwd)"* ]]; then
        script_path="$(command -v db-backupper)"
    else
        script_path="$(cd "$(dirname "${BASH_SOURCE[-1]}")" && pwd)/db-backupper"
    fi
    
    # Determine appropriate log directory based on installation
    if [[ "$script_path" == "/usr/local/bin/db-backupper" ]] || [[ "$script_path" == "/usr/bin/db-backupper" ]]; then
        # System-wide installation
        log_dir="/var/log/db-backupper"
    else
        # Local installation
        log_dir="$HOME/.local/log/db-backupper"
    fi
    
    # Create safe database name for logging
    if [[ -n "${DB_NAME:-}" ]]; then
        db_name_safe=$(echo "$DB_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]_-')
    else
        db_name_safe="database"
    fi
    
    echo "========================================="
    echo "DB-BACKUPPER CRONTAB EXAMPLES"
    echo "========================================="
    echo
    
    # Warning section
    log_warning "IMPORTANT: Always use --prefix to separate different environments!"
    log_warning "Examples: --prefix 'production/', --prefix 'staging/', --prefix 'development/'"
    echo
    
    echo "Detected script path: $script_path"
    echo "Recommended log directory: $log_dir"
    echo
    
    # Try to create log directory
    if [[ ! -d "$log_dir" ]]; then
        if mkdir -p "$log_dir" 2>/dev/null; then
            log_info "Created log directory: $log_dir"
        else
            log_warning "Could not create log directory: $log_dir"
            echo "Please create it manually with: sudo mkdir -p '$log_dir' && sudo chown \$(id -u):\$(id -g) '$log_dir'"
        fi
    else
        log_info "Log directory exists: $log_dir"
    fi
    
    echo
    echo "CRONTAB EXAMPLES:"
    echo "=================="
    echo
    
    echo "# Add these lines to your crontab with: crontab -e"
    echo "# Or for system-wide: sudo crontab -e"
    echo
    
    echo "# Daily backup at 2:00 AM (production environment)"
    echo "0 2 * * * $script_path backup --prefix \"production/\" >> $log_dir/${db_name_safe}_backup.log 2>&1"
    echo
    
    echo "# Weekly backup on Sunday at 3:00 AM"
    echo "0 3 * * 0 $script_path backup --prefix \"weekly/\" >> $log_dir/${db_name_safe}_weekly.log 2>&1"
    echo
    
    echo "# Monthly backup on the 1st at 4:00 AM"
    echo "0 4 1 * * $script_path backup --prefix \"monthly/\" >> $log_dir/${db_name_safe}_monthly.log 2>&1"
    echo
    
    echo "# Staging environment backup (daily at 1:00 AM)"
    echo "0 1 * * * $script_path backup --prefix \"staging/\" >> $log_dir/${db_name_safe}_staging.log 2>&1"
    echo
    
    echo "CRONTAB TIME FORMAT:"
    echo "==================="
    echo "# ┌───────────── minute (0 - 59)"
    echo "# │ ┌───────────── hour (0 - 23)"
    echo "# │ │ ┌───────────── day of the month (1 - 31)"
    echo "# │ │ │ ┌───────────── month (1 - 12)"
    echo "# │ │ │ │ ┌───────────── day of the week (0 - 6) (Sunday to Saturday)"
    echo "# │ │ │ │ │"
    echo "# │ │ │ │ │"
    echo "# * * * * * command to execute"
    echo
    
    echo "LOG MANAGEMENT RECOMMENDATIONS:"
    echo "==============================="
    echo "# Set up log rotation to prevent disk space issues"
    echo "# Create /etc/logrotate.d/db-backupper with:"
    echo "cat > /etc/logrotate.d/db-backupper << 'EOF'"
    echo "$log_dir/*.log {"
    echo "    daily"
    echo "    rotate 30"
    echo "    compress"
    echo "    delaycompress"
    echo "    missingok"
    echo "    notifempty"
    echo "    create 644 \$(id -u) \$(id -g)"
    echo "}"
    echo "EOF"
    echo
    
    echo "TESTING YOUR CRONTAB:"
    echo "===================="
    echo "# Test the backup command manually first:"
    echo "$script_path backup --prefix \"test/\""
    echo
    echo "# Monitor the log files:"
    echo "tail -f $log_dir/${db_name_safe}_backup.log"
    echo
    
    log_info "Crontab examples generated successfully!"
}