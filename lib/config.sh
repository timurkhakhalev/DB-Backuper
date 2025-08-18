#!/usr/bin/env bash
# Configuration loading and validation for db-backupper

# Securely load configuration without executing arbitrary code
load_config_secure() {
    local config_file="$1"
    local line_num=0
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_num++))
        
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        
        # Parse key=value pairs
        if [[ "$line" =~ ^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            
            # Validate against whitelist
            case "$key" in
                AWS_PROFILE|S3_BUCKET_NAME|S3_BACKUP_PATH|POSTGRES_URI|DOCKER_CONTAINER_NAME)
                    # Remove quotes if present
                    value="${value%\"}"
                    value="${value#\"}"
                    value="${value%\'}"
                    value="${value#\'}"
                    
                    # Set variable safely
                    declare -g "$key=$value"
                    ;;
                *)
                    log_error "Unknown configuration variable '$key' at line $line_num"
                    exit 1
                    ;;
            esac
        else
            log_error "Invalid configuration syntax at line $line_num: $line"
            exit 1
        fi
    done < "$config_file"
}

# Load configuration from backup.conf
load_config() {
    local script_dir="$1"
    local config_file="${script_dir}/backup.conf"
    
    if [[ ! -f "$config_file" ]]; then
        log_error "Configuration file not found at $config_file"
        log_error "Please copy backup.conf.example to backup.conf and fill in your details."
        exit 1
    fi
    
    # Securely load configuration file
    load_config_secure "$config_file"
    
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