# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a PostgreSQL Docker backup and restore tool for AWS S3 storage. It's a modular Bash application that provides automated database backup/restore operations with comprehensive error handling and flexible deployment options.

## Architecture

The tool follows a clean modular architecture:

- **db-backupper**: Main executable that orchestrates operations
- **lib/**: Modular library components
  - `config.sh`: Configuration loading and validation
  - `database.sh`: PostgreSQL operations (pg_dump, psql via Docker)
  - `backup.sh`: Backup functionality with S3 upload
  - `restore.sh`: Restore operations with database management
  - `utils.sh`: Logging, PATH setup, command validation

## Key Commands

### Development/Testing
```bash
# Test the tool without installation
./db-backupper help

# Install system-wide
sudo ./install.sh

# Install for current user only  
./install.sh --user

# Basic operations
db-backupper backup
db-backupper backup --prefix "production/"
db-backupper download s3://bucket/path/to/backup.tar.gz
db-backupper restore ./dump_file.sql --purge
```

### Configuration
Configuration is read from `backup.conf` in this order:
1. `./backup.conf` (current directory)
2. `~/.config/db-backupper/backup.conf` (user config)  
3. `/etc/db-backupper/backup.conf` (system config)

Copy `backup.conf.example` to create your configuration.

## Development Notes

### Required Dependencies
- AWS CLI (configured with appropriate S3 permissions)
- Docker (with PostgreSQL container)
- Standard Unix tools: tar, find, sed, tr
- PostgreSQL client tools (pg_dump, psql) available inside the Docker container

### Error Handling
- Uses `set -eo pipefail` for strict error handling
- All functions include comprehensive error checking
- Logging functions (`log_info`, `log_error`) with timestamps in `utils.sh:5-11`

### Path Management
The tool includes robust PATH setup for cron environments in `utils.sh:22-35`, ensuring commands are found in automated environments.

### Security Considerations
- Configuration files are automatically set to 600 permissions
- Database credentials passed as environment variables to Docker
- S3 access requires specific IAM permissions (PutObject, GetObject, ListBucket)

### Testing Approach
Test operations manually using:
- `db-backupper backup --prefix "test/"` for backup testing
- `db-backupper restore-legacy s3://...` for quick restore testing
- Verify AWS CLI and Docker connectivity before testing

## Common Workflows

1. **Development Setup**: Copy `backup.conf.example` to `backup.conf` and configure AWS/PostgreSQL settings
2. **Installation Testing**: Use `./install.sh --user` for user-level testing
3. **Backup Testing**: Use `--prefix "test/"` to separate test backups
4. **Restore Testing**: Use `--no-purge` flag to avoid data loss during testing