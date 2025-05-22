#!/usr/bin/env bash
set -eo pipefail # Exit on error, treat unset variables as an error, and propagate pipeline failures

# --- Configuration Loading ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/backup.conf"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Configuration file not found at $CONFIG_FILE"
    echo "Please copy db_backup.conf.example to db_backup.conf and fill in your details."
    exit 1
fi

# Source the configuration file
# shellcheck source=db_backup.conf.example
source "$CONFIG_FILE"

# --- Validate Configuration ---
REQUIRED_VARS=(AWS_PROFILE S3_BUCKET_NAME POSTGRES_URI DOCKER_CONTAINER_NAME)
MISSING_VARS=0
for VAR_NAME in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!VAR_NAME}" ]]; then
        echo "ERROR: Required configuration variable '$VAR_NAME' is not set in $CONFIG_FILE."
        MISSING_VARS=1
    fi
done
[[ "$MISSING_VARS" -eq 1 ]] && exit 1

# --- Helper Functions ---
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

# Parse PostgreSQL URI
# Expected format: postgresql://user:password@host:port/dbname
parse_postgres_uri() {
    local uri="$1"
    # Remove protocol
    uri="${uri#postgresql://}"
    # Extract user and password
    DB_USER_PASS="${uri%%@*}"
    DB_USER="${DB_USER_PASS%%:*}"
    DB_PASS="${DB_USER_PASS#*:}"
    # Extract host, port, and dbname
    uri_remainder="${uri#*@}"
    DB_HOST_PORT_DB="${uri_remainder}"
    DB_HOST_PORT="${DB_HOST_PORT_DB%%/*}"
    DB_NAME="${DB_HOST_PORT_DB#*/}"

    if [[ "$DB_HOST_PORT" == *":"* ]]; then
        DB_HOST="${DB_HOST_PORT%%:*}"
        DB_PORT="${DB_HOST_PORT#*:}"
    else
        DB_HOST="$DB_HOST_PORT"
        DB_PORT="5432" # Default PostgreSQL port
    fi

    if [[ -z "$DB_USER" || -z "$DB_HOST" || -z "$DB_NAME" ]]; then
        log_error "Could not parse POSTGRES_URI. Ensure it's in the format: postgresql://user:password@host:port/dbname or postgresql://user@host/dbname (password will be prompted or use .pgpass)"
        exit 1
    fi
}

# --- Main Actions ---

# Action: Backup database, compress, and upload to S3
action_backup() {
    local backup_prefix_arg="$1" # Optional prefix from command line
    log_info "Starting database backup..."
    parse_postgres_uri "$POSTGRES_URI"

    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    
    local prefix_segment=""
    if [[ -n "$backup_prefix_arg" ]]; then
        local sanitized_prefix
        # 1. Replace common separators (space, dot, slash, etc.) with underscore. And collapse multiple resulting underscores.
        sanitized_prefix=$(echo "$backup_prefix_arg" | tr ' ./[:space:]' '_' | tr -s '_')
        # 2. Remove any characters not suitable for filenames (keep alphanumeric, underscore, hyphen)
        sanitized_prefix=$(echo "$sanitized_prefix" | sed 's/[^a-zA-Z0-9_-]//g')
        # 3. Remove leading/trailing underscores/hyphens
        sanitized_prefix=$(echo "$sanitized_prefix" | sed -e 's/^[_+-]*//' -e 's/[_+-]*$//')
        
        # 4. If after all this, it's not empty and contains at least one alphanumeric char, use it.
        if [[ -n "$sanitized_prefix" && "$sanitized_prefix" =~ [a-zA-Z0-9] ]]; then
            prefix_segment="${sanitized_prefix}_" # Append underscore separator
        else
            log_info "Warning: Provided prefix '$backup_prefix_arg' resulted in an empty or invalid string after sanitization. No prefix will be used."
            prefix_segment=""
        fi
    fi

    local dump_filename="dump_${prefix_segment}${DB_NAME}_${timestamp}.sql"
    local archive_filename="${prefix_segment}${DB_NAME}_${timestamp}.tar.gz"
    
    local temp_dir
    temp_dir=$(mktemp -d)
    trap 'rm -rf -- "$temp_dir"' EXIT # Cleanup temp dir on exit

    local local_dump_path="${temp_dir}/${dump_filename}"
    local local_archive_path="${temp_dir}/${archive_filename}"

    log_info "Dumping database '$DB_NAME' from container '$DOCKER_CONTAINER_NAME'..."
    # pg_dump command (plain text SQL format)
    docker exec -i \
        -e PGPASSWORD="$DB_PASS" \
        "$DOCKER_CONTAINER_NAME" \
        pg_dump -U "$DB_USER" -h "$DB_HOST" -p "$DB_PORT" -d "$DB_NAME" \
                --no-owner --no-privileges -F p \
                > "$local_dump_path"

    if [[ $? -ne 0 || ! -s "$local_dump_path" ]]; then
        log_error "Database dump failed or dump file is empty."
        exit 1
    fi
    log_info "Database dump created: $local_dump_path (original name in tar: $dump_filename)"

    log_info "Compressing dump file into $archive_filename..."
    tar -czf "$local_archive_path" -C "$temp_dir" "$dump_filename"
    log_info "Archive created: $local_archive_path"

    local s3_key="${S3_BACKUP_PATH}${archive_filename}"
    local s3_full_url="s3://${S3_BUCKET_NAME}/${s3_key}"

    log_info "Uploading archive to S3: $s3_full_url"
    aws s3 cp "$local_archive_path" "$s3_full_url" --profile "$AWS_PROFILE"
    if [[ $? -ne 0 ]]; then
        log_error "S3 upload failed."
        exit 1
    fi

    log_info "Backup successful! Archive uploaded to $s3_full_url"
    log_info "You can restore using: $0 restore $s3_full_url"
    rm -rf -- "$temp_dir" # Explicit cleanup, trap will also run
    trap - EXIT # Clear trap
}

# Action: Download from S3, decompress, and restore to database
action_restore() {
    local s3_url="$1"
    # s3_url is already validated by main before calling this.

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
    # Extract and find the .sql file (assuming only one .sql file in the root of the tar)
    # And that its name starts with "dump_" and ends with ".sql"
    tar -xzf "$local_archive_path" -C "$temp_dir"
    # Robustly find the SQL file, assuming it's the only .sql file starting with dump_ in the temp_dir root
    extracted_dump_path=$(find "$temp_dir" -maxdepth 1 -type f -name "dump_*.sql" -print -quit)


    if [[ -z "$extracted_dump_path" || ! -s "$extracted_dump_path" ]]; then
        log_error "Failed to extract SQL dump file from archive or extracted file is empty."
        log_error "Searched for files matching 'dump_*.sql' in the archive root."
        ls -la "$temp_dir" # List contents of temp_dir for debugging
        exit 1
    fi
    log_info "SQL dump extracted: $extracted_dump_path"

    log_info "Restoring database '$DB_NAME' in container '$DOCKER_CONTAINER_NAME'..."
    log_info "WARNING: This will typically overwrite existing data in tables defined in the dump."
    docker exec -i \
        -e PGPASSWORD="$DB_PASS" \
        "$DOCKER_CONTAINER_NAME" \
        psql -U "$DB_USER" -h "$DB_HOST" -p "$DB_PORT" -d "$DB_NAME" \
             --quiet --single-transaction --set ON_ERROR_STOP=1 \
        < "$extracted_dump_path"

    if [[ $? -ne 0 ]]; then
        log_error "Database restore failed."
        exit 1
    fi

    log_info "Database restore successful!"
    rm -rf -- "$temp_dir" # Explicit cleanup
    trap - EXIT # Clear trap
}

# --- Usage and Argument Parsing ---
usage() {
    echo "Usage: $0 <action> [options]"
    echo ""
    echo "Actions:"
    echo "  backup [--prefix <string>]  Dump PostgreSQL DB, compress, and upload to S3."
    echo "                              --prefix: Optional string to prepend to the backup filename."
    echo "                                        e.g., 'myproject' results in 'backup_myproject_dbname_timestamp.tar.gz'"
    echo "  restore <s3_url>          Download archive from S3, decompress, and restore to PostgreSQL DB."
    echo "                              <s3_url> is the full S3 path, e.g., s3://${S3_BUCKET_NAME}/${S3_BACKUP_PATH}backup_prefix_dbname_timestamp.tar.gz"
    echo "  help                      Show this help message."
    echo ""
    echo "Configuration is read from: $CONFIG_FILE"
}

main() {
    # Check for required commands globally
    check_command "aws"
    check_command "docker"
    check_command "tar"
    check_command "find" # Used in restore
    check_command "sed"  # Used for prefix sanitization
    check_command "tr"   # Used for prefix sanitization
    # pg_dump and psql are run inside docker, so not checked on host

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
        restore)
            if [[ $# -eq 0 ]]; then
                log_error "ERROR: S3 URL must be provided for restore."
                usage
                exit 1
            fi
            if [[ $# -gt 1 ]]; then # Check if more than one argument (the S3 URL) is provided
                log_error "ERROR: Too many arguments for restore. Expected S3 URL only. Got: $*"
                usage
                exit 1
            fi
            local s3_url_for_restore="$1"
             # Validate S3 URL format
            if [[ ! "$s3_url_for_restore" =~ ^s3:// ]]; then
                log_error "Invalid S3 URL format for restore. Expected: s3://bucket-name/path/to/archive.tar.gz"
                exit 1
            fi
            action_restore "$s3_url_for_restore"
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

# --- Script Entry Point ---
main "$@"