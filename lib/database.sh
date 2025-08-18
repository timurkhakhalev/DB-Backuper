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


# Execute psql command using connection URI
execute_psql_secure() {
    docker exec -i \
        "$DOCKER_CONTAINER_NAME" \
        psql "$POSTGRES_URI" "$@"
    
    return $?
}

# Execute pg_dump using connection URI
execute_pgdump_secure() {
    docker exec -i \
        "$DOCKER_CONTAINER_NAME" \
        pg_dump "$POSTGRES_URI" "$@"
    
    return $?
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
    
    execute_pgdump_secure --no-owner --no-privileges -F p > "$dump_path"
    
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
    
    # Create postgres connection URI by replacing database name
    local postgres_uri="${POSTGRES_URI%/*}/postgres"
    
    # First terminate any existing connections to the database
    local quoted_db_name
    quoted_db_name=$(quote_identifier "$DB_NAME")
    
    docker exec -i "$DOCKER_CONTAINER_NAME" \
        psql "$postgres_uri" --quiet -v ON_ERROR_STOP=off \
        -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $quoted_db_name;"
             
    # Drop and create the database
    local temp_sql_file=$(mktemp)
    cat > "$temp_sql_file" << EOF
DROP DATABASE IF EXISTS $quoted_db_name;
CREATE DATABASE $quoted_db_name;
EOF
    
    docker exec -i "$DOCKER_CONTAINER_NAME" \
        psql "$postgres_uri" --quiet --no-psqlrc --no-align --tuples-only < "$temp_sql_file"
    
    local status=$?
    rm -f "$temp_sql_file"
    
    if [[ $status -ne 0 ]]; then
        log_error "Failed to drop/create database."
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
    
    docker exec -i "$DOCKER_CONTAINER_NAME" \
        psql "$POSTGRES_URI" --quiet --set ON_ERROR_STOP=1 < "$dump_path"
    
    return $?
}