# PostgreSQL Docker Backup & Restore Tool for S3

This Bash tool automates the process of:
1.  Dumping a PostgreSQL database running in a Docker container.
2.  Compressing the dump into a `.tar.gz` archive.
3.  Uploading the archive to an AWS S3 bucket.
4.  Downloading an archive from S3.
5.  Decompressing the archive and restoring the dump to a PostgreSQL database in Docker.

## Prerequisites

1.  **Bash:** The script is written for Bash.
2.  **AWS CLI:** Installed and configured. The script uses an AWS profile for authentication.
    *   Install: `https://aws.amazon.com/cli/`
    *   Configure: Run `aws configure --profile <your-profile-name>` (e.g., `aws configure --profile s3-manager`) or ensure your default profile has S3 access, or the instance has an IAM role with S3 permissions.
3.  **Docker:** Installed and running. The target PostgreSQL database must be running in a Docker container.
    *   Install: `https://docs.docker.com/get-docker/`
4.  **`tar` utility:** Usually pre-installed on Linux/macOS.
5.  **PostgreSQL Client Tools (`pg_dump`, `psql`):** These must be available *inside* the specified PostgreSQL Docker container. Standard PostgreSQL images (e.g., `postgres:latest`) include these.

## Installation

1.  **Clone or Download:**
    Get the files into a directory on your system, for example, `db_backup_tool/`.
    ```bash
    git clone <repository_url> db_backup_tool
    cd db_backup_tool
    ```
    Or, manually create the directory and files as provided.

2.  **Configure:**
    Copy the example configuration file and edit it with your details:
    ```bash
    cp db_backup.conf.example db_backup.conf
    nano db_backup.conf # or your favorite editor
    ```
    Fill in the following:
    *   `AWS_PROFILE`: Your AWS CLI profile name.
    *   `S3_BUCKET_NAME`: The S3 bucket for storing backups.
    *   `S3_BACKUP_PATH` (Optional): A path prefix within the S3 bucket (e.g., `my_app/db_dumps/`). Remember the trailing slash if used.
    *   `POSTGRES_URI`: Connection string for your PostgreSQL database (e.g., `postgresql://pguser:pgpass@localhost:5432/mydb`).
        *   The `host` here is from the perspective of *inside* the Docker container where `pg_dump` and `psql` will run. If it's the same container, `localhost` is usually correct. If it's another container on the same Docker network, use its service name.
    *   `DOCKER_CONTAINER_NAME`: The name or ID of your running PostgreSQL Docker container.

3.  **Make Executable:**
    Give the main script execution permissions:
    ```bash
    chmod +x db_backup.sh
    ```

## Usage

### Create a Cronjob

```bash
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 0 */3 * * /home/ubuntu/backuper/db_backup.sh --prefix "weekly/" >> /home/ubuntu/backuper/logs/weekly.log 2>&1
```

Navigate to the `db_backup_tool` directory.

### Create a Backup

This will dump the database, compress it, and upload it to S3.

```bash
./db_backup.sh backup
```
On success, it will output the S3 URL of the created backup.

### Backup with a Filename Prefix:
Use the --prefix option to add a prefix to the generated backup filename. The prefix will be sanitized (spaces become underscores, special characters removed).
```bash
./db_backup.sh backup --prefix myproject
```
Example filename on S3: backup_myproject_mydb_20230101_120000.tar.gz

### Restore from Backup

This will download a specified archive from S3, decompress it, and restore it to the database.

```bash
./db_backup.sh restore s3://your-s3-bucket-name/path/to/your/backup_dbname_timestamp.tar.gz
```

Replace s3://your-s3-bucket-name/path/to/your/backup_dbname_timestamp.tar.gz with the actual S3 URL of the backup archive you want to restore.

**Warning**: The restore operation will typically overwrite tables in the target database that are defined in the dump file. The pg_dump command used by this script generates a plain SQL dump which usually includes DROP TABLE IF EXISTS statements.

### Get Help

```bash
./db_backup.sh help
```

### Important Notes

**Security**:

The POSTGRES_URI in db_backup.conf contains database credentials. Ensure this file has appropriate permissions (e.g., chmod 600 db_backup.conf).

The script passes PGPASSWORD as an environment variable to docker exec. While convenient, this can be visible in process lists on the host. For higher security, consider configuring .pgpass within the Docker container image or using Docker secrets if your setup supports it.

**AWS IAM profile/role**:

Ensure your AWS IAM profile/role has minimal necessary S3 permissions (e.g., s3:PutObject for backup, s3:GetObject for restore, limited to the specific bucket/path).

**Docker Container**:
Docker Container: The DOCKER_CONTAINER_NAME must be correct and the container must be running. The container also needs to have pg_dump and psql client tools installed (standard PostgreSQL images do).

**Error Handling**:

The script uses set -eo pipefail for basic error handling. If a command fails, the script should exit. For restore operations, a partial restore might occur if psql fails mid-way (though --single-transaction and ON_ERROR_STOP=1 help mitigate this for many cases). Always verify critical restores.

**Dump Format**:

This script uses pg_dump -F p (plain SQL format). For very large databases or if you need features like parallel restore, you might consider pg_dump -Fc (custom format) and pg_restore. This would require modifying the script.
