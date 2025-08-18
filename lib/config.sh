#!/usr/bin/env bash
# Configuration loading and validation for db-backupper

# Securely load configuration without executing arbitrary code
load_config_secure() {
    local config_file="$1"
    local line_num=0
    
    log_info "Loading configuration from: $config_file"
    
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
                    log_info "Loaded config: $key=[REDACTED]"
                    ;;
                *)
                    log_error "Unknown configuration variable '$key' at line $line_num"
                    log_error "Valid variables are: AWS_PROFILE, S3_BUCKET_NAME, S3_BACKUP_PATH, POSTGRES_URI, DOCKER_CONTAINER_NAME"
                    exit 1
                    ;;
            esac
        else
            log_error "Invalid configuration syntax at line $line_num: $line"
            exit 1
        fi
    done < "$config_file"
    
    log_info "Configuration file parsing completed"
}

# Load configuration from backup.conf
load_config() {
    local config_file=""
    
    # Check configuration locations in order of precedence
    local config_locations=(
        "./backup.conf"                                    # Current directory
        "${HOME}/.config/db-backupper/backup.conf"        # User config
        "/etc/db-backupper/backup.conf"                   # System config
    )
    
    for location in "${config_locations[@]}"; do
        if [[ -f "$location" ]]; then
            config_file="$location"
            log_info "Using configuration file: $config_file"
            break
        fi
    done
    
    if [[ -z "$config_file" ]]; then
        log_error "Configuration file not found in any of these locations:"
        for location in "${config_locations[@]}"; do
            log_error "  - $location"
        done
        log_error "Please copy backup.conf.example to one of these locations and fill in your details."
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
    
    log_info "Starting configuration validation..."
    
    for var_name in "${required_vars[@]}"; do
        local var_value="${!var_name}"
        if [[ -z "$var_value" ]]; then
            log_error "Required configuration variable '$var_name' is not set in backup.conf."
            missing_vars=1
        else
            log_info "✓ $var_name is set"
        fi
    done
    
    if [[ "$missing_vars" -eq 1 ]]; then
        log_error "Configuration validation failed. Please check your backup.conf file."
        exit 1
    fi
    
    log_info "Configuration validation passed successfully."
}