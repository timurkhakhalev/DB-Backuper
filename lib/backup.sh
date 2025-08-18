#!/usr/bin/env bash
# Backup functionality for db-backupper

# Action: Backup database, compress, and upload to S3
action_backup() {
    local backup_prefix_arg="$1" # Optional prefix from command line
    log_info "Starting database backup..."
    parse_postgres_uri "$POSTGRES_URI"

    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    
    local prefix_segment=""
    if [[ -n "$backup_prefix_arg" ]]; then
        # Use the prefix as-is without sanitization since it's for S3 directory path
        prefix_segment="${backup_prefix_arg}"
        # Add trailing slash if not present, to make it work as a directory
        if [[ ! "$prefix_segment" =~ /$ ]]; then
            prefix_segment="${prefix_segment}/"
        fi
    fi

    local dump_filename="dump_${DB_NAME}_${timestamp}.sql"
    local archive_filename="${DB_NAME}_${timestamp}.tar.gz"
    
    local temp_dir
    temp_dir=$(mktemp -d)
    trap 'rm -rf -- "$temp_dir"' EXIT # Cleanup temp dir on exit

    local local_dump_path="${temp_dir}/${dump_filename}"
    local local_archive_path="${temp_dir}/${archive_filename}"

    if ! execute_dump "$local_dump_path"; then
        exit 1
    fi
    log_info "Database dump created: $local_dump_path (original name in tar: $dump_filename)"

    log_info "Compressing dump file into $archive_filename..."
    tar -czf "$local_archive_path" -C "$temp_dir" "$dump_filename"
    log_info "Archive created: $local_archive_path"

    local s3_key="${S3_BACKUP_PATH}${prefix_segment}${archive_filename}"
    local s3_full_url="s3://${S3_BUCKET_NAME}/${s3_key}"

    log_info "Uploading archive to S3: $s3_full_url"
    aws s3 cp "$local_archive_path" "$s3_full_url" --profile "$AWS_PROFILE"
    if [[ $? -ne 0 ]]; then
        log_error "S3 upload failed."
        exit 1
    fi

    log_info "Backup successful! Archive uploaded to $s3_full_url"
    log_info "You can restore using: db-backupper download $s3_full_url and then db-backupper restore path/to/downloaded/dump.sql"
    rm -rf -- "$temp_dir" # Explicit cleanup, trap will also run
    trap - EXIT # Clear trap
}