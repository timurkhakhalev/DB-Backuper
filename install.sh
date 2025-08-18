#!/usr/bin/env bash
set -eo pipefail

# Installation script for db-backupper
# Installs db-backupper as a global command and sets up configuration

INSTALL_DIR="/usr/local/bin"
CONFIG_DIRS=("/etc/db-backupper" "$HOME/.config/db-backupper")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

check_root() {
    if [[ $EUID -eq 0 ]]; then
        return 0  # Running as root
    else
        return 1  # Not running as root
    fi
}

install_system_wide() {
    log_info "Installing db-backupper system-wide..."
    
    # Create the lib directory in /usr/local/lib
    sudo mkdir -p /usr/local/lib/db-backupper
    
    # Copy the lib files
    sudo cp -r "${SCRIPT_DIR}/lib/"* /usr/local/lib/db-backupper/
    
    # Create the main executable with adjusted paths
    sudo tee "${INSTALL_DIR}/db-backupper" > /dev/null <<'EOF'
#!/usr/bin/env bash
set -eo pipefail

# db-backupper - PostgreSQL Docker Backup & Restore Tool for S3
# Globally installed version

SCRIPT_DIR="/usr/local/lib/db-backupper"

# Source utility functions first (includes path setup)
source "${SCRIPT_DIR}/utils.sh"

# Set up robust PATH for cron environments
setup_path

# Determine the configuration directory
CONFIG_DIR="$(get_script_dir)"

# Source all modules
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/database.sh"
source "${SCRIPT_DIR}/backup.sh"
source "${SCRIPT_DIR}/restore.sh"

# Load configuration
load_config "$CONFIG_DIR"

# Usage information
usage() {
    echo "Usage: db-backupper <action> [options]"
    echo ""
    echo "Actions:"
    echo "  backup [--prefix <string>]  Dump PostgreSQL DB, compress, and upload to S3."
    echo "                              --prefix: Optional path prefix for S3 storage location."
    echo "                                        e.g., 'folder1/folder2/' results in storing at 'S3_BACKUP_PATH/folder1/folder2/dbname_timestamp.tar.gz'"
    echo "  download <s3_url> [dir]     Download archive from S3 and extract to current directory or specified directory."
    echo "                              <s3_url> is the full S3 path, e.g., s3://bucket-name/path/to/archive.tar.gz"
    echo "                              [dir] is an optional output directory (defaults to current directory)"
    echo "  restore <dump_path> [--purge|--no-purge]"
    echo "                              Restore from a SQL dump file. Optional flags to control database purging:"
    echo "                              --purge: Drop and recreate the database before restoring"
    echo "                              --no-purge: Preserve existing database (default, will ask if neither specified)"
    echo "  restore-legacy <s3_url>     (DEPRECATED) Download archive from S3, decompress, and restore to PostgreSQL DB in one step."
    echo "                              <s3_url> is the full S3 path, e.g., s3://bucket-name/path/to/archive.tar.gz"
    echo "  help                        Show this help message."
    echo ""
    echo "Configuration locations (checked in order):"
    echo "  1. ./backup.conf (current directory)"
    echo "  2. ~/.config/db-backupper/backup.conf"
    echo "  3. /etc/db-backupper/backup.conf"
    echo ""
    echo "Example workflow:"
    echo "  1. db-backupper download s3://bucket-name/path/dbname_timestamp.tar.gz"
    echo "  2. db-backupper restore ./dump_dbname_timestamp.sql --purge"
}

# Main function
main() {
    # Check for required commands globally
    check_all_commands

    if [[ $# -eq 0 ]]; then
        usage
        exit 1
    fi

    local action="$1"
    shift # Consume the action

    case "$action" in
        backup)
            local backup_filename_prefix_arg=""
            # Parse options for backup
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --prefix)
                        if [[ -z "$2" ]]; then # Check if $2 is empty or not provided
                            log_error "ERROR: --prefix requires an argument."
                            usage
                            exit 1
                        fi
                        backup_filename_prefix_arg="$2"
                        shift 2 # Consume --prefix and its value
                        ;;
                    *)
                        log_error "ERROR: Unknown option or argument for backup: $1"
                        usage
                        exit 1
                        ;;
                esac
            done
            action_backup "$backup_filename_prefix_arg"
            ;;
        download)
            if [[ $# -eq 0 ]]; then
                log_error "ERROR: S3 URL must be provided for download."
                usage
                exit 1
            fi
            local s3_url_for_download="$1"
            local output_dir="${2:-$(pwd)}"
            # Validate S3 URL format
            if [[ ! "$s3_url_for_download" =~ ^s3:// ]]; then
                log_error "Invalid S3 URL format for download. Expected: s3://bucket-name/path/to/archive.tar.gz"
                exit 1
            fi
            action_download "$s3_url_for_download" "$output_dir"
            ;;
        restore)
            if [[ $# -eq 0 ]]; then
                log_error "ERROR: SQL dump file path must be provided for restore."
                usage
                exit 1
            fi
            local dump_path="$1"
            local purge_option="${2:-}"
            action_restore "$dump_path" "$purge_option"
            ;;
        restore-legacy)
            if [[ $# -eq 0 ]]; then
                log_error "ERROR: S3 URL must be provided for restore-legacy."
                usage
                exit 1
            fi
            if [[ $# -gt 1 ]]; then
                log_error "ERROR: Too many arguments for restore-legacy. Expected S3 URL only. Got: $*"
                usage
                exit 1
            fi
            local s3_url_for_restore="$1"
             # Validate S3 URL format
            if [[ ! "$s3_url_for_restore" =~ ^s3:// ]]; then
                log_error "Invalid S3 URL format for restore. Expected: s3://bucket-name/path/to/archive.tar.gz"
                exit 1
            fi
            action_restore_legacy "$s3_url_for_restore"
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            # If action itself is -h or --help, it wasn't caught above, handle here
            if [[ "$action" == "-h" || "$action" == "--help" ]]; then
                 usage
                 exit 0
            fi
            log_error "Invalid action: '$action'"
            usage
            exit 1
            ;;
    esac
}

# Script entry point
main "$@"
EOF

    # Make executable
    sudo chmod +x "${INSTALL_DIR}/db-backupper"
    
    log_success "db-backupper installed to ${INSTALL_DIR}/db-backupper"
    log_success "Library files installed to /usr/local/lib/db-backupper/"
}

install_user_only() {
    log_info "Installing db-backupper for current user only..."
    
    # Create user's local bin directory
    mkdir -p "$HOME/.local/bin"
    mkdir -p "$HOME/.local/lib/db-backupper"
    
    # Copy the lib files
    cp -r "${SCRIPT_DIR}/lib/"* "$HOME/.local/lib/db-backupper/"
    
    # Create the main executable with adjusted paths
    cat > "$HOME/.local/bin/db-backupper" <<'EOF'
#!/usr/bin/env bash
set -eo pipefail

# db-backupper - PostgreSQL Docker Backup & Restore Tool for S3
# User installation version

SCRIPT_DIR="$HOME/.local/lib/db-backupper"

# Source utility functions first (includes path setup)
source "${SCRIPT_DIR}/utils.sh"

# Set up robust PATH for cron environments
setup_path

# Determine the configuration directory
CONFIG_DIR="$(get_script_dir)"

# Source all modules
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/database.sh"
source "${SCRIPT_DIR}/backup.sh"
source "${SCRIPT_DIR}/restore.sh"

# Load configuration
load_config "$CONFIG_DIR"

# Usage information
usage() {
    echo "Usage: db-backupper <action> [options]"
    echo ""
    echo "Actions:"
    echo "  backup [--prefix <string>]  Dump PostgreSQL DB, compress, and upload to S3."
    echo "                              --prefix: Optional path prefix for S3 storage location."
    echo "                                        e.g., 'folder1/folder2/' results in storing at 'S3_BACKUP_PATH/folder1/folder2/dbname_timestamp.tar.gz'"
    echo "  download <s3_url> [dir]     Download archive from S3 and extract to current directory or specified directory."
    echo "                              <s3_url> is the full S3 path, e.g., s3://bucket-name/path/to/archive.tar.gz"
    echo "                              [dir] is an optional output directory (defaults to current directory)"
    echo "  restore <dump_path> [--purge|--no-purge]"
    echo "                              Restore from a SQL dump file. Optional flags to control database purging:"
    echo "                              --purge: Drop and recreate the database before restoring"
    echo "                              --no-purge: Preserve existing database (default, will ask if neither specified)"
    echo "  restore-legacy <s3_url>     (DEPRECATED) Download archive from S3, decompress, and restore to PostgreSQL DB in one step."
    echo "                              <s3_url> is the full S3 path, e.g., s3://bucket-name/path/to/archive.tar.gz"
    echo "  help                        Show this help message."
    echo ""
    echo "Configuration locations (checked in order):"
    echo "  1. ./backup.conf (current directory)"
    echo "  2. ~/.config/db-backupper/backup.conf"
    echo "  3. /etc/db-backupper/backup.conf"
    echo ""
    echo "Example workflow:"
    echo "  1. db-backupper download s3://bucket-name/path/dbname_timestamp.tar.gz"
    echo "  2. db-backupper restore ./dump_dbname_timestamp.sql --purge"
}

# Main function
main() {
    # Check for required commands globally
    check_all_commands

    if [[ $# -eq 0 ]]; then
        usage
        exit 1
    fi

    local action="$1"
    shift # Consume the action

    case "$action" in
        backup)
            local backup_filename_prefix_arg=""
            # Parse options for backup
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --prefix)
                        if [[ -z "$2" ]]; then # Check if $2 is empty or not provided
                            log_error "ERROR: --prefix requires an argument."
                            usage
                            exit 1
                        fi
                        backup_filename_prefix_arg="$2"
                        shift 2 # Consume --prefix and its value
                        ;;
                    *)
                        log_error "ERROR: Unknown option or argument for backup: $1"
                        usage
                        exit 1
                        ;;
                esac
            done
            action_backup "$backup_filename_prefix_arg"
            ;;
        download)
            if [[ $# -eq 0 ]]; then
                log_error "ERROR: S3 URL must be provided for download."
                usage
                exit 1
            fi
            local s3_url_for_download="$1"
            local output_dir="${2:-$(pwd)}"
            # Validate S3 URL format
            if [[ ! "$s3_url_for_download" =~ ^s3:// ]]; then
                log_error "Invalid S3 URL format for download. Expected: s3://bucket-name/path/to/archive.tar.gz"
                exit 1
            fi
            action_download "$s3_url_for_download" "$output_dir"
            ;;
        restore)
            if [[ $# -eq 0 ]]; then
                log_error "ERROR: SQL dump file path must be provided for restore."
                usage
                exit 1
            fi
            local dump_path="$1"
            local purge_option="${2:-}"
            action_restore "$dump_path" "$purge_option"
            ;;
        restore-legacy)
            if [[ $# -eq 0 ]]; then
                log_error "ERROR: S3 URL must be provided for restore-legacy."
                usage
                exit 1
            fi
            if [[ $# -gt 1 ]]; then
                log_error "ERROR: Too many arguments for restore-legacy. Expected S3 URL only. Got: $*"
                usage
                exit 1
            fi
            local s3_url_for_restore="$1"
             # Validate S3 URL format
            if [[ ! "$s3_url_for_restore" =~ ^s3:// ]]; then
                log_error "Invalid S3 URL format for restore. Expected: s3://bucket-name/path/to/archive.tar.gz"
                exit 1
            fi
            action_restore_legacy "$s3_url_for_restore"
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            # If action itself is -h or --help, it wasn't caught above, handle here
            if [[ "$action" == "-h" || "$action" == "--help" ]]; then
                 usage
                 exit 0
            fi
            log_error "Invalid action: '$action'"
            usage
            exit 1
            ;;
    esac
}

# Script entry point
main "$@"
EOF

    # Make executable
    chmod +x "$HOME/.local/bin/db-backupper"
    
    log_success "db-backupper installed to $HOME/.local/bin/db-backupper"
    log_success "Library files installed to $HOME/.local/lib/db-backupper/"
    
    # Check if ~/.local/bin is in PATH
    if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
        log_warning "$HOME/.local/bin is not in your PATH"
        log_info "Add this to your ~/.bashrc or ~/.zshrc:"
        echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
    fi
}

setup_config() {
    local config_dir="$1"
    
    log_info "Setting up configuration directory: $config_dir"
    
    if check_root && [[ "$config_dir" == "/etc/db-backupper" ]]; then
        sudo mkdir -p "$config_dir"
        if [[ ! -f "$config_dir/backup.conf" ]]; then
            sudo cp "${SCRIPT_DIR}/backup.conf.example" "$config_dir/backup.conf"
            sudo chmod 600 "$config_dir/backup.conf"
            log_success "Configuration template created at $config_dir/backup.conf"
            log_warning "Please edit $config_dir/backup.conf with your settings"
        else
            log_info "Configuration file already exists at $config_dir/backup.conf"
        fi
    else
        mkdir -p "$config_dir"
        if [[ ! -f "$config_dir/backup.conf" ]]; then
            cp "${SCRIPT_DIR}/backup.conf.example" "$config_dir/backup.conf"
            chmod 600 "$config_dir/backup.conf"
            log_success "Configuration template created at $config_dir/backup.conf"
            log_warning "Please edit $config_dir/backup.conf with your settings"
        else
            log_info "Configuration file already exists at $config_dir/backup.conf"
        fi
    fi
}

main() {
    log_info "db-backupper installation script"
    
    # Check if files exist
    if [[ ! -f "${SCRIPT_DIR}/db-backupper" ]]; then
        log_error "db-backupper executable not found in ${SCRIPT_DIR}"
        exit 1
    fi
    
    if [[ ! -d "${SCRIPT_DIR}/lib" ]]; then
        log_error "lib directory not found in ${SCRIPT_DIR}"
        exit 1
    fi
    
    # Parse command line arguments
    local install_type="auto"
    local setup_config_flag=true
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --system)
                install_type="system"
                shift
                ;;
            --user)
                install_type="user"
                shift
                ;;
            --no-config)
                setup_config_flag=false
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [--system|--user] [--no-config]"
                echo ""
                echo "Options:"
                echo "  --system     Install system-wide (requires sudo)"
                echo "  --user       Install for current user only"
                echo "  --no-config  Don't set up configuration files"
                echo "  --help       Show this help"
                echo ""
                echo "If no installation type is specified, the script will:"
                echo "  - Try system-wide installation if running as root"
                echo "  - Fall back to user installation otherwise"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    # Determine installation method
    if [[ "$install_type" == "auto" ]]; then
        if check_root; then
            install_type="system"
        else
            install_type="user"
        fi
    fi
    
    # Perform installation
    case "$install_type" in
        system)
            if ! check_root; then
                log_error "System-wide installation requires root privileges"
                log_info "Please run with sudo or use --user for user installation"
                exit 1
            fi
            install_system_wide
            if [[ "$setup_config_flag" == true ]]; then
                setup_config "/etc/db-backupper"
            fi
            ;;
        user)
            install_user_only
            if [[ "$setup_config_flag" == true ]]; then
                setup_config "$HOME/.config/db-backupper"
            fi
            ;;
    esac
    
    log_success "Installation complete!"
    log_info "Run 'db-backupper help' to see usage information"
    
    if [[ "$setup_config_flag" == true ]]; then
        log_info "Don't forget to configure your backup.conf file with your AWS and database settings"
    fi
}

main "$@"