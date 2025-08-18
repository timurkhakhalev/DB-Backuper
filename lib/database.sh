#!/usr/bin/env bash
# Database operations for db-backupper

# Validate database identifier (name)
validate_db_identifier() {
    local identifier="$1"
    # Only allow alphanumeric, underscore, hyphen
    if [[ ! "$identifier" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
        log_error "Invalid database identifier: $identifier"
        return 1
    fi
    # Check length (PostgreSQL limit is 63 chars)
    if [[ ${#identifier} -gt 63 ]]; then
        log_error "Database identifier too long: $identifier"
        return 1
    fi
    return 0
}

# Quote database identifier for safe SQL usage
quote_identifier() {
    local identifier="$1"
    # Use PostgreSQL double-quote escaping
    echo "\"${identifier//\"/\"\"}\""
}

# Validate container name
validate_container_name() {
    local container="$1"
    # Allow alphanumeric, underscore, hyphen, and dots
    if [[ ! "$container" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        log_error "Invalid container name: $container"
        return 1
    fi
    return 0
}

# Setup secure .pgpass file for authentication
setup_pgpass() {
    local temp_pgpass
    temp_pgpass=$(mktemp)
    chmod 600 "$temp_pgpass"
    
    # Create .pgpass entry: hostname:port:database:username:password
    echo "$DB_HOST:$DB_PORT:*:$DB_USER:$DB_PASS" > "$temp_pgpass"
    
    # Return the temp file path
    echo "$temp_pgpass"
}

# Execute psql command securely without exposing password
execute_psql_secure() {
    local pgpass_file
    pgpass_file=$(setup_pgpass)
    
    # Use .pgpass file instead of PGPASSWORD
    docker exec -i \
        -e PGPASSFILE="/.pgpass" \
        -v "$pgpass_file:/.pgpass:ro" \
        "$DOCKER_CONTAINER_NAME" \
        psql -U "$DB_USER" -h "$DB_HOST" -p "$DB_PORT" "$@"
    
    local exit_code=$?
    
    # Cleanup
    rm -f "$pgpass_file"
    
    return $exit_code
}

# Execute pg_dump securely without exposing password
execute_pgdump_secure() {
    local pgpass_file
    pgpass_file=$(setup_pgpass)
    
    # Use .pgpass file instead of PGPASSWORD
    docker exec -i \
        -e PGPASSFILE="/.pgpass" \
        -v "$pgpass_file:/.pgpass:ro" \
        "$DOCKER_CONTAINER_NAME" \
        pg_dump -U "$DB_USER" -h "$DB_HOST" -p "$DB_PORT" "$@"
    
    local exit_code=$?
    
    # Cleanup
    rm -f "$pgpass_file"
    
    return $exit_code
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
    
    # Validate database name for security
    if ! validate_db_identifier "$DB_NAME"; then
        log_error "Database name contains invalid characters or is too long"
        exit 1
    fi
}

# Execute database dump
execute_dump() {
    local dump_path="$1"
    
    # Validate container name
    if ! validate_container_name "$DOCKER_CONTAINER_NAME"; then
        log_error "Invalid container name: $DOCKER_CONTAINER_NAME"
        return 1
    fi
    
    log_info "Dumping database '$DB_NAME' from container '$DOCKER_CONTAINER_NAME'..."
    
    execute_pgdump_secure -d "$DB_NAME" --no-owner --no-privileges -F p > "$dump_path"
    
    if [[ $? -ne 0 || ! -s "$dump_path" ]]; then
        log_error "Database dump failed or dump file is empty."
        return 1
    fi
    
    return 0
}

# Purge database (drop and recreate)
purge_database() {
    log_info "Purging database '$DB_NAME' before restore..."
    
    # Validate container name
    if ! validate_container_name "$DOCKER_CONTAINER_NAME"; then
        log_error "Invalid container name: $DOCKER_CONTAINER_NAME"
        return 1
    fi
    
    # First terminate any existing connections to the database
    local quoted_db_name
    quoted_db_name=$(quote_identifier "$DB_NAME")
    execute_psql_secure -d "postgres" --quiet -v ON_ERROR_STOP=off \
        -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $quoted_db_name;"
             
    # Drop the database - run with autocommit mode (using separate command execution)
    local temp_sql_file=$(mktemp)
    echo "DROP DATABASE IF EXISTS $quoted_db_name;" > "$temp_sql_file"
    
    execute_psql_secure -d "postgres" --quiet --no-psqlrc --no-align --tuples-only -f - < "$temp_sql_file"
    
    local drop_status=$?
    rm -f "$temp_sql_file"
    
    if [[ $drop_status -ne 0 ]]; then
        log_error "Failed to drop database. This might be due to active connections."
        return 1
    fi
    
    # Create the database using a temporary file
    local temp_create_sql=$(mktemp)
    echo "CREATE DATABASE $quoted_db_name;" > "$temp_create_sql"
    
    execute_psql_secure -d "postgres" --quiet --no-psqlrc --no-align --tuples-only -f - < "$temp_create_sql"
    
    local create_status=$?
    rm -f "$temp_create_sql"
    
    if [[ $create_status -ne 0 ]]; then
        log_error "Failed to create database."
        return 1
    fi
    
    log_info "Database purged successfully."
    return 0
}

# Execute database restore
execute_restore() {
    local dump_path="$1"
    
    # Validate container name
    if ! validate_container_name "$DOCKER_CONTAINER_NAME"; then
        log_error "Invalid container name: $DOCKER_CONTAINER_NAME"
        return 1
    fi
    
    log_info "Starting database restore. This may take a while..."
    
    execute_psql_secure -d "$DB_NAME" --quiet --set ON_ERROR_STOP=1 < "$dump_path"
    
    return $?
}