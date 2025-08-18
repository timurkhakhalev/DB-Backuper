#!/usr/bin/env bash
# Configuration loading and validation for db-backupper

# Load configuration from backup.conf
load_config() {
    local script_dir="$1"
    local config_file="${script_dir}/backup.conf"
    
    if [[ ! -f "$config_file" ]]; then
        log_error "Configuration file not found at $config_file"
        log_error "Please copy backup.conf.example to backup.conf and fill in your details."
        exit 1
    fi
    
    # Source the configuration file
    # shellcheck source=backup.conf.example
    source "$config_file"
    
    validate_config
}

# Validate required configuration variables
validate_config() {
    local required_vars=(AWS_PROFILE S3_BUCKET_NAME POSTGRES_URI DOCKER_CONTAINER_NAME)
    local missing_vars=0
    
    for var_name in "${required_vars[@]}"; do
        if [[ -z "${!var_name}" ]]; then
            log_error "Required configuration variable '$var_name' is not set in backup.conf."
            missing_vars=1
        fi
    done
    
    if [[ "$missing_vars" -eq 1 ]]; then
        exit 1
    fi
}