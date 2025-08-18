# Development Guide for db-backupper

This guide covers development setup, testing procedures, architecture details, and contribution guidelines for the db-backupper tool.

## Development Environment Setup

### Prerequisites

1. **Development Tools**:
   ```bash
   # Essential development tools
   sudo apt update
   sudo apt install -y bash shellcheck git make
   
   # For testing
   sudo apt install -y bats-core  # Bash testing framework (optional)
   ```

2. **Runtime Dependencies**:
   ```bash
   # AWS CLI
   curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
   unzip awscliv2.zip
   sudo ./aws/install
   
   # Docker
   curl -fsSL https://get.docker.com -o get-docker.sh
   sudo sh get-docker.sh
   sudo usermod -aG docker $USER
   ```

3. **PostgreSQL Test Container**:
   ```bash
   # Start a test PostgreSQL container
   docker run --name postgres-test \
     -e POSTGRES_PASSWORD=testpassword \
     -e POSTGRES_USER=testuser \
     -e POSTGRES_DB=testdb \
     -p 5432:5432 \
     -d postgres:15
   ```

### Local Development Setup

1. **Clone and Setup**:
   ```bash
   git clone <repository_url> db-backupper
   cd db-backupper
   
   # Make scripts executable
   chmod +x db-backupper install.sh
   chmod +x lib/*.sh test/*.sh
   ```

2. **Development Configuration**:
   ```bash
   # Copy example configuration
   cp backup.conf.example backup.conf
   
   # Edit for local testing
   nano backup.conf
   ```
   
   Example development configuration:
   ```bash
   AWS_PROFILE="default"
   S3_BUCKET_NAME="your-test-bucket"
   S3_BACKUP_PATH="dev_backups/"
   POSTGRES_URI="postgresql://testuser:testpassword@localhost:5432/testdb"
   DOCKER_CONTAINER_NAME="postgres-test"
   ```

3. **Test Installation**:
   ```bash
   # Install for current user (recommended for development)
   ./install.sh --user
   
   # Test the installation
   db-backupper help
   ```

## Architecture Overview

### Modular Design

The tool follows a clean modular architecture with separation of concerns:

```
db-backupper/
├── db-backupper              # Main executable and CLI interface
├── install.sh               # Installation script with user/system options
├── backup.conf.example      # Configuration template
├── lib/                     # Core library modules
│   ├── utils.sh            # Logging, PATH setup, resource monitoring
│   ├── config.sh           # Secure configuration loading and validation
│   ├── database.sh         # PostgreSQL operations, URI parsing, security
│   ├── backup.sh           # Backup workflow, S3 operations, path security
│   └── restore.sh          # Restore workflow, archive security, validation
├── test/                    # Test suites and validation
│   └── security-tests.sh   # Comprehensive security testing
├── .tasks/                  # Development plans and analysis
│   ├── README.md           # Overview of improvement tasks
│   ├── edge-case-analysis.md        # 67 identified edge cases
│   ├── security-fixes-plan.md       # Security hardening roadmap
│   ├── reliability-improvements-plan.md  # Reliability enhancements
│   └── implementation-checklist.md # Progress tracking
└── CLAUDE.md               # AI development context and guidelines
```

### Module Responsibilities

#### `utils.sh` - Core Utilities
- **Logging system**: `log_info()`, `log_error()`, `log_warning()`
- **PATH management**: Robust PATH setup for cron environments
- **Command validation**: Check for required system dependencies
- **Resource monitoring**: Disk space, memory usage, timeout handling
- **Configuration discovery**: Multi-location config file resolution

#### `config.sh` - Configuration Management
- **Secure loading**: Prevents code injection via `load_config_secure()`
- **Variable validation**: Whitelist-based configuration validation
- **Multi-location support**: `./backup.conf` → `~/.config/` → `/etc/`
- **Error handling**: Comprehensive validation with detailed error messages

#### `database.sh` - PostgreSQL Operations
- **URI parsing**: Secure PostgreSQL connection string handling
- **Security features**: Input validation, SQL injection prevention
- **Docker integration**: Secure container command execution
- **Credential management**: `.pgpass` file system for secure authentication
- **Database operations**: `execute_dump()`, `execute_restore()`, `purge_database()`

#### `backup.sh` - Backup Workflow
- **S3 integration**: Upload with error handling and validation
- **Archive creation**: Compressed tar.gz backup files
- **Path security**: Sanitized S3 prefix handling
- **Progress tracking**: Logging and status reporting

#### `restore.sh` - Restore Workflow  
- **Download management**: S3 download with validation
- **Archive security**: Safe tar extraction with path traversal protection
- **Database restoration**: Interactive and automated restore options
- **Legacy support**: Backward compatibility for existing workflows

## Security Architecture

The tool implements comprehensive security hardening based on identification of 67 edge cases:

### Critical Security Features

1. **SQL Injection Prevention**:
   - `validate_db_identifier()`: Strict database name validation
   - `quote_identifier()`: PostgreSQL identifier escaping
   - Validated SQL statement construction

2. **Command Injection Prevention**:
   - `validate_container_name()`: Docker container name validation
   - Secure command array construction
   - Input sanitization for all external commands

3. **Configuration Security**:
   - `load_config_secure()`: Parse-only configuration loading
   - Variable whitelist validation
   - No arbitrary code execution

4. **Credential Protection**:
   - `.pgpass` file system instead of environment variables
   - Temporary credential files with secure permissions
   - Process list protection

5. **Path Traversal Prevention**:
   - `sanitize_s3_prefix()`: S3 path sanitization
   - `secure_tar_extract()`: Safe archive extraction
   - Directory traversal attack prevention

## Testing Framework

### Test Structure

```
test/
└── security-tests.sh        # Comprehensive security test suite
```

### Security Test Suite

The security test suite (`test/security-tests.sh`) provides comprehensive validation:

```bash
# Run security tests
./test/security-tests.sh
```

**Test Categories**:
1. **SQL Injection Tests**: Malicious database names and valid cases
2. **Command Injection Tests**: Container name validation
3. **Configuration Security**: Malicious config file handling
4. **Path Traversal Tests**: S3 prefix and archive path validation
5. **Archive Security**: Tar extraction safety
6. **Resource Monitoring**: Disk space and memory validation

### Manual Testing Procedures

#### 1. Basic Functionality Testing

```bash
# Test backup creation
db-backupper backup --prefix "test/"

# Test download functionality
db-backupper download s3://your-bucket/path/to/test/backup.tar.gz

# Test restore functionality
db-backupper restore ./downloaded_dump.sql --no-purge
```

#### 2. Security Testing

```bash
# Test malicious database names (should be rejected)
POSTGRES_URI="postgresql://user:pass@host/malicious; DROP TABLE users; --" \
  db-backupper backup

# Test path traversal (should be sanitized)
db-backupper backup --prefix "../../../etc/"

# Test malicious container names (should be rejected)
DOCKER_CONTAINER_NAME="container; rm -rf /" \
  db-backupper backup
```

#### 3. Error Handling Testing

```bash
# Test missing configuration
rm backup.conf
db-backupper backup  # Should fail with clear error

# Test invalid S3 credentials
AWS_PROFILE="nonexistent" db-backupper backup

# Test network failures (disconnect network during operation)
```

#### 4. Resource Testing

```bash
# Test disk space monitoring (fill /tmp to test limits)
# Test large database dumps
# Test memory usage patterns
```

### Automated Testing Integration

#### GitHub Actions Example

```yaml
name: Security and Integration Tests

on: [push, pull_request]

jobs:
  security-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Setup test environment
        run: |
          sudo apt-get update
          sudo apt-get install -y shellcheck
      - name: Lint shell scripts  
        run: find . -name "*.sh" -exec shellcheck {} \;
      - name: Run security tests
        run: ./test/security-tests.sh
```

#### Pre-commit Hooks

```bash
# Setup pre-commit hooks
cat > .git/hooks/pre-commit << 'EOF'
#!/bin/bash
# Run shellcheck on all shell scripts
find . -name "*.sh" -exec shellcheck {} \;
exit_code=$?

if [ $exit_code -ne 0 ]; then
    echo "ShellCheck failed. Please fix issues before committing."
    exit 1
fi

# Run security tests
./test/security-tests.sh
EOF

chmod +x .git/hooks/pre-commit
```

## Development Workflows

### Adding New Features

1. **Plan the feature**:
   - Update `.tasks/` documentation if it's a major feature
   - Consider security implications
   - Design module interactions

2. **Implement with security first**:
   - Add input validation
   - Follow existing patterns
   - Update relevant lib/*.sh files

3. **Add tests**:
   - Update `test/security-tests.sh` with new test cases
   - Add manual testing procedures
   - Test edge cases and failure modes

4. **Update documentation**:
   - Update `README.md` for user-facing changes
   - Update `DEVELOPMENT.md` for developer changes
   - Update `CLAUDE.md` if architecture changes

### Security-First Development

**Always consider**:
- Input validation and sanitization
- Command injection prevention  
- Path traversal protection
- Resource exhaustion protection
- Credential security
- Error message information disclosure

**Security checklist for new features**:
- [ ] All user inputs validated
- [ ] No arbitrary command execution
- [ ] Safe file operations
- [ ] Proper error handling
- [ ] Resource limits considered
- [ ] Security tests added

### Code Quality Standards

#### Shell Script Best Practices

```bash
#!/usr/bin/env bash
# Always use strict mode
set -euo pipefail

# Use shellcheck directives
# shellcheck source=lib/utils.sh
source "lib/utils.sh"

# Local variables
function example_function() {
    local param="$1"
    local result
    
    # Input validation
    if [[ -z "$param" ]]; then
        log_error "Parameter required"
        return 1
    fi
    
    # Safe command execution
    result=$(some_command "$param") || {
        log_error "Command failed"
        return 1
    }
    
    echo "$result"
}
```

#### Documentation Standards

- **Functions**: Document purpose, parameters, return values
- **Security**: Document security considerations
- **Examples**: Provide usage examples
- **Error cases**: Document failure modes

## Performance Considerations

### Resource Management

- **Memory usage**: Monitor pg_dump memory consumption
- **Disk space**: Pre-check available space before operations
- **Network**: Handle S3 upload/download timeouts and retries
- **Concurrent operations**: Prevent multiple simultaneous backups

### Optimization Opportunities

1. **Parallel operations**: Multi-threaded S3 uploads
2. **Compression levels**: Configurable compression settings
3. **Resume capability**: Resumable S3 uploads for large files
4. **Progress reporting**: Real-time progress for long operations

## Troubleshooting Development Issues

### Common Development Problems

1. **ShellCheck errors**:
   ```bash
   # Fix common issues
   shellcheck lib/*.sh db-backupper
   ```

2. **Permission errors**:
   ```bash
   # Fix script permissions
   chmod +x db-backupper lib/*.sh test/*.sh
   ```

3. **PATH issues in testing**:
   ```bash
   # Test PATH resolution
   which db-backupper
   echo $PATH
   ```

4. **Configuration not found**:
   ```bash
   # Debug config file discovery
   strace -e trace=openat db-backupper backup 2>&1 | grep backup.conf
   ```

### Debugging Techniques

```bash
# Enable debug output
set -x  # Add to scripts for detailed tracing

# Test individual functions
source lib/database.sh
validate_db_identifier "test_db"

# Test with minimal config
cat > test.conf << EOF
AWS_PROFILE="default"
S3_BUCKET_NAME="test-bucket"  
POSTGRES_URI="postgresql://test:test@localhost:5432/test"
DOCKER_CONTAINER_NAME="postgres-test"
EOF
```

## Contributing Guidelines

### Pull Request Process

1. **Fork and branch**:
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Make changes following security-first principles**

3. **Test thoroughly**:
   ```bash
   ./test/security-tests.sh
   shellcheck lib/*.sh
   ```

4. **Update documentation**

5. **Submit PR with**:
   - Clear description of changes
   - Security impact assessment
   - Test results
   - Breaking change notes

### Code Review Checklist

- [ ] Security implications reviewed
- [ ] Input validation added
- [ ] Error handling appropriate
- [ ] Tests added/updated
- [ ] Documentation updated
- [ ] Backward compatibility maintained
- [ ] ShellCheck passes
- [ ] Manual testing completed

## Release Process

### Version Management

- **Major version**: Breaking changes, architecture changes
- **Minor version**: New features, security enhancements  
- **Patch version**: Bug fixes, security patches

### Release Checklist

1. [ ] All tests pass
2. [ ] Security audit completed
3. [ ] Documentation updated
4. [ ] Version numbers updated
5. [ ] Changelog updated
6. [ ] Installation tested on clean system
7. [ ] Backward compatibility verified

This development guide ensures consistent, secure, and maintainable development practices for the db-backupper tool.