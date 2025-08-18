#!/usr/bin/env bash
# Database operations for db-backupper

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

# Execute database dump
execute_dump() {
    local dump_path="$1"
    
    log_info "Dumping database '$DB_NAME' from container '$DOCKER_CONTAINER_NAME'..."
    
    docker exec -i \
        -e PGPASSWORD="$DB_PASS" \
        "$DOCKER_CONTAINER_NAME" \
        pg_dump -U "$DB_USER" -h "$DB_HOST" -p "$DB_PORT" -d "$DB_NAME" \
                --no-owner --no-privileges -F p \
                > "$dump_path"
    
    if [[ $? -ne 0 || ! -s "$dump_path" ]]; then
        log_error "Database dump failed or dump file is empty."
        return 1
    fi
    
    return 0
}

# Purge database (drop and recreate)
purge_database() {
    log_info "Purging database '$DB_NAME' before restore..."
    
    # First terminate any existing connections to the database
    docker exec -i \
        -e PGPASSWORD="$DB_PASS" \
        "$DOCKER_CONTAINER_NAME" \
        psql -U "$DB_USER" -h "$DB_HOST" -p "$DB_PORT" -d "postgres" \
             --quiet -v ON_ERROR_STOP=off \
             -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB_NAME';"
             
    # Drop the database - run with autocommit mode (using separate command execution)
    local temp_sql_file=$(mktemp)
    echo "DROP DATABASE IF EXISTS $DB_NAME;" > "$temp_sql_file"
    
    docker exec -i \
        -e PGPASSWORD="$DB_PASS" \
        "$DOCKER_CONTAINER_NAME" \
        psql -U "$DB_USER" -h "$DB_HOST" -p "$DB_PORT" -d "postgres" \
             --quiet --no-psqlrc --no-align --tuples-only \
             -f - < "$temp_sql_file"
    
    local drop_status=$?
    rm -f "$temp_sql_file"
    
    if [[ $drop_status -ne 0 ]]; then
        log_error "Failed to drop database. This might be due to active connections."
        return 1
    fi
    
    # Create the database using a temporary file
    local temp_create_sql=$(mktemp)
    echo "CREATE DATABASE $DB_NAME;" > "$temp_create_sql"
    
    docker exec -i \
        -e PGPASSWORD="$DB_PASS" \
        "$DOCKER_CONTAINER_NAME" \
        psql -U "$DB_USER" -h "$DB_HOST" -p "$DB_PORT" -d "postgres" \
             --quiet --no-psqlrc --no-align --tuples-only \
             -f - < "$temp_create_sql"
    
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
    
    log_info "Starting database restore. This may take a while..."
    
    docker exec -i \
        -e PGPASSWORD="$DB_PASS" \
        "$DOCKER_CONTAINER_NAME" \
        psql -U "$DB_USER" -h "$DB_HOST" -p "$DB_PORT" -d "$DB_NAME" \
             --quiet --set ON_ERROR_STOP=1 \
        < "$dump_path"
    
    return $?
}