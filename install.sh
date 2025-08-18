#!/usr/bin/env bash
set -eo pipefail

# Installation script for db-backupper
# Installs db-backupper as a global command and sets up configuration

INSTALL_DIR="/usr/local/bin"
LIB_DIR="/usr/local/lib/db-backupper"
CONFIG_DIR="/etc/db-backupper"
USER_BIN_DIR="$HOME/.local/bin"
USER_LIB_DIR="$HOME/.local/lib/db-backupper"
USER_CONFIG_DIR="$HOME/.config/db-backupper"
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
    [[ $EUID -eq 0 ]]
}

install_system_wide() {
    log_info "Installing db-backupper system-wide..."
    
    # Create directories
    sudo mkdir -p "$LIB_DIR"
    
    # Copy library files
    sudo cp -r "${SCRIPT_DIR}/lib/"* "$LIB_DIR/"
    
    # Copy main script and update SCRIPT_DIR
    sudo cp "${SCRIPT_DIR}/db-backupper" "${INSTALL_DIR}/db-backupper"
    sudo sed -i "s|^SCRIPT_DIR=.*|SCRIPT_DIR=\"$LIB_DIR\"|" "${INSTALL_DIR}/db-backupper"
    sudo chmod +x "${INSTALL_DIR}/db-backupper"
    
    log_success "db-backupper installed to ${INSTALL_DIR}/db-backupper"
    log_success "Library files installed to $LIB_DIR/"
}

install_user_only() {
    log_info "Installing db-backupper for current user only..."
    
    # Create directories
    mkdir -p "$USER_BIN_DIR" "$USER_LIB_DIR"
    
    # Copy library files
    cp -r "${SCRIPT_DIR}/lib/"* "$USER_LIB_DIR/"
    
    # Copy main script and update SCRIPT_DIR
    cp "${SCRIPT_DIR}/db-backupper" "$USER_BIN_DIR/db-backupper"
    sed -i "s|^SCRIPT_DIR=.*|SCRIPT_DIR=\"$USER_LIB_DIR\"|" "$USER_BIN_DIR/db-backupper"
    chmod +x "$USER_BIN_DIR/db-backupper"
    
    log_success "db-backupper installed to $USER_BIN_DIR/db-backupper"
    log_success "Library files installed to $USER_LIB_DIR/"
    
    # Check if ~/.local/bin is in PATH
    if [[ ":$PATH:" != *":$USER_BIN_DIR:"* ]]; then
        log_warning "$USER_BIN_DIR is not in your PATH"
        log_info "Add this to your ~/.bashrc or ~/.zshrc:"
        echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
    fi
}

setup_config() {
    local target_config_dir="$1"
    
    log_info "Setting up configuration directory: $target_config_dir"
    
    if check_root && [[ "$target_config_dir" == "$CONFIG_DIR" ]]; then
        sudo mkdir -p "$target_config_dir"
        if [[ ! -f "$target_config_dir/backup.conf" ]]; then
            sudo cp "${SCRIPT_DIR}/backup.conf.example" "$target_config_dir/backup.conf"
            sudo chmod 600 "$target_config_dir/backup.conf"
            log_success "Configuration template created at $target_config_dir/backup.conf"
            log_warning "Please edit $target_config_dir/backup.conf with your settings"
        else
            log_info "Configuration file already exists at $target_config_dir/backup.conf"
        fi
    else
        mkdir -p "$target_config_dir"
        if [[ ! -f "$target_config_dir/backup.conf" ]]; then
            cp "${SCRIPT_DIR}/backup.conf.example" "$target_config_dir/backup.conf"
            chmod 600 "$target_config_dir/backup.conf"
            log_success "Configuration template created at $target_config_dir/backup.conf"
            log_warning "Please edit $target_config_dir/backup.conf with your settings"
        else
            log_info "Configuration file already exists at $target_config_dir/backup.conf"
        fi
    fi
}

usage() {
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
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
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
                setup_config "$CONFIG_DIR"
            fi
            ;;
        user)
            install_user_only
            if [[ "$setup_config_flag" == true ]]; then
                setup_config "$USER_CONFIG_DIR"
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