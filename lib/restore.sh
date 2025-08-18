#!/usr/bin/env bash
# Restore functionality for db-backupper

# Securely extract tar archive with path traversal protection
secure_tar_extract() {
    local archive_path="$1"
    local extract_dir="$2"
    
    # Validate archive exists and is readable
    if [[ ! -f "$archive_path" || ! -r "$archive_path" ]]; then
        log_error "Archive not found or not readable: $archive_path"
        return 1
    fi
    
    # Check if it's a valid tar.gz file
    if ! tar -tzf "$archive_path" >/dev/null 2>&1; then
        log_error "Invalid or corrupted archive: $archive_path"
        return 1
    fi
    
    # List contents and validate paths
    local file_list
    file_list=$(tar -tzf "$archive_path")
    
    while IFS= read -r file_path; do
        # Check for path traversal attempts
        if [[ "$file_path" =~ \.\./|/\.\./ ]] || [[ "$file_path" =~ ^/ ]]; then
            log_error "Security violation: path traversal detected in archive: $file_path"
            return 1
        fi
        
        # Check for device files or symlinks (basic check)
        if [[ "$file_path" =~ ^/dev/|^/proc/|^/sys/ ]]; then
            log_error "Security violation: system path in archive: $file_path"
            return 1
        fi
        
        # Limit path depth to prevent zip bomb-like attacks
        local depth
        depth=$(echo "$file_path" | tr '/' '\n' | wc -l)
        if [[ $depth -gt 10 ]]; then
            log_error "Security violation: path too deep in archive: $file_path"
            return 1
        fi
    done <<< "$file_list"
    
    # Extract with additional security measures
    tar -xzf "$archive_path" -C "$extract_dir" --no-same-owner --no-same-permissions
    
    return $?
}

# Action: Download from S3 and decompress
action_download() {
    local s3_url="$1"
    local output_dir="${2:-$(pwd)}"
    
    # Validate S3 URL format
    if [[ ! "$s3_url" =~ ^s3:// ]]; then
        log_error "Invalid S3 URL format. Expected: s3://bucket-name/path/to/archive.tar.gz"
        exit 1
    fi

    log_info "Starting database backup download from $s3_url..."
    
    local archive_filename
    archive_filename=$(basename "$s3_url")
    local temp_dir
    temp_dir=$(mktemp -d)
    trap 'rm -rf -- "$temp_dir"' EXIT # Cleanup temp dir on exit

    local local_archive_path="${temp_dir}/${archive_filename}"

    log_info "Downloading archive from S3: $s3_url"
    aws s3 cp "$s3_url" "$local_archive_path" --profile "$AWS_PROFILE"
    if [[ $? -ne 0 || ! -s "$local_archive_path" ]]; then
        log_error "S3 download failed or downloaded file is empty."
        exit 1
    fi
    log_info "Archive downloaded: $local_archive_path"

    log_info "Decompressing archive to $output_dir..."
    # Extract and find the .sql file using secure extraction
    if ! secure_tar_extract "$local_archive_path" "$output_dir"; then
        log_error "Failed to extract archive securely"
        exit 1
    fi
    
    # Robustly find the SQL file
    local extracted_dump_path
    extracted_dump_path=$(find "$output_dir" -maxdepth 1 -type f -name "dump_*.sql" -print -quit)

    if [[ -z "$extracted_dump_path" || ! -s "$extracted_dump_path" ]]; then
        log_error "Failed to extract SQL dump file from archive or extracted file is empty."
        log_error "Searched for files matching 'dump_*.sql' in the output directory."
        ls -la "$output_dir" # List contents for debugging
        exit 1
    fi
    log_info "SQL dump extracted: $extracted_dump_path"
    log_info "Download and extraction successful!"
    log_info "You can now restore using: db-backupper restore $extracted_dump_path"
    
    trap - EXIT # Clear trap
}

# Action: Restore database from SQL dump
action_restore() {
    local dump_path="$1"
    local purge_option="$2"
    
    if [[ ! -f "$dump_path" ]]; then
        log_error "SQL dump file not found at $dump_path"
        exit 1
    fi
    
    log_info "Starting database restore from $dump_path..."
    parse_postgres_uri "$POSTGRES_URI"

    # Ask user about purging the database if not specified
    local should_purge=false
    if [[ "$purge_option" == "--purge" ]]; then
        should_purge=true
    elif [[ "$purge_option" != "--no-purge" ]]; then
        read -p "Do you want to purge (drop and recreate) the current database before restoring? (y/N): " user_response
        if [[ "${user_response,,}" == "y" || "${user_response,,}" == "yes" ]]; then
            should_purge=true
        fi
    fi

    log_info "Restoring database '$DB_NAME' in container '$DOCKER_CONTAINER_NAME'..."
    
    if [[ "$should_purge" == true ]]; then
        if ! purge_database; then
            exit 1
        fi
    else
        log_info "WARNING: This will merge data with existing tables. Conflicts may occur."
    fi

    if ! execute_restore "$dump_path"; then
        log_error "Database restore failed."
        exit 1
    fi

    log_info "Database restore successful!"
}

# Legacy restore action (kept for backward compatibility)
action_restore_legacy() {
    local s3_url="$1"

    log_info "DEPRECATED: This restore method will be removed in future versions."
    log_info "Please use 'download' followed by 'restore' instead."
    log_info "Starting database restore from $s3_url..."
    
    parse_postgres_uri "$POSTGRES_URI"

    local archive_filename
    archive_filename=$(basename "$s3_url")
    local temp_dir
    temp_dir=$(mktemp -d)
    trap 'rm -rf -- "$temp_dir"' EXIT # Cleanup temp dir on exit

    local local_archive_path="${temp_dir}/${archive_filename}"
    local extracted_dump_path # Will be set after tar extraction

    log_info "Downloading archive from S3: $s3_url"
    aws s3 cp "$s3_url" "$local_archive_path" --profile "$AWS_PROFILE"
    if [[ $? -ne 0 || ! -s "$local_archive_path" ]]; then
        log_error "S3 download failed or downloaded file is empty."
        exit 1
    fi
    log_info "Archive downloaded: $local_archive_path"

    log_info "Decompressing archive..."
    # Extract and find the .sql file using secure extraction
    if ! secure_tar_extract "$local_archive_path" "$temp_dir"; then
        log_error "Failed to extract archive securely"
        exit 1
    fi
    # Robustly find the SQL file, assuming it's the only .sql file starting with dump_ in the temp_dir root
    extracted_dump_path=$(find "$temp_dir" -maxdepth 1 -type f -name "dump_*.sql" -print -quit)

    if [[ -z "$extracted_dump_path" || ! -s "$extracted_dump_path" ]]; then
        log_error "Failed to extract SQL dump file from archive or extracted file is empty."
        log_error "Searched for files matching 'dump_*.sql' in the archive root."
        ls -la "$temp_dir" # List contents of temp_dir for debugging
        exit 1
    fi
    log_info "SQL dump extracted: $extracted_dump_path"

    # Validate container name
    if ! validate_container_name "$DOCKER_CONTAINER_NAME"; then
        log_error "Invalid container name: $DOCKER_CONTAINER_NAME"
        exit 1
    fi
    
    log_info "Restoring database '$DB_NAME' in container '$DOCKER_CONTAINER_NAME'..."
    log_info "WARNING: This will typically overwrite existing data in tables defined in the dump."
    execute_psql_secure -d "$DB_NAME" --quiet --single-transaction --set ON_ERROR_STOP=1 < "$extracted_dump_path"

    if [[ $? -ne 0 ]]; then
        log_error "Database restore failed."
        exit 1
    fi

    log_info "Database restore successful!"
    rm -rf -- "$temp_dir" # Explicit cleanup
    trap - EXIT # Clear trap
}