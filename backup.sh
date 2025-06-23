#!/bin/bash

# Before configuring the cron job, make sure to set the following S3 bucket configuration is done:
# Enable Versioning on Your S3 Bucket:
#   Go to the S3 console.
#   Select your bucket.
#   Click on the “Properties” tab.
#   Enable versioning.
# Set Up Lifecycle Policies:
#   In the S3 console, go to the “Management” tab of your bucket.
#   Click on “Lifecycle rules” and create a new rule.
#   Configure the rule to delete previous versions of objects after a certain number of days.

# Function to log messages
log_message() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >&2
}

check_required_env() {
    local required_env
    local missing_vars
    required_env=("$@")
    missing_vars=()

    for var_to_verify in "${required_env[@]}"; do
        if [ -z "${!var_to_verify}" ]; then
            missing_vars+=("$var_to_verify")
        fi
    done

    if [ ${#missing_vars[@]} -ne 0 ]; then
        log_message "Error: ${missing_vars[*]} are not set."
        exit 1
    fi
}

# for all the files with .env ext in the current directory, load them into the environment
SCRIPT_DIR="$(dirname "$0")"
if [ ! -d "$SCRIPT_DIR" ]; then
    log_message "Error: Script directory $SCRIPT_DIR does not exist."
    exit 1
fi

pushd "$SCRIPT_DIR" > /dev/null || exit 1

for env_file in *.env; do
    if [ -f "$env_file" ]; then
        source "$env_file" || { log_message "Error: Failed to load $env_file"; exit 1; }
        log_message "Loaded environment variables from $env_file"
    fi
done

popd > /dev/null || exit 1

# Set default values and generate timestamp
BACKUP_PREFIX_PATH=$HOME/backup
DATE=$(date +%Y%m%d%H%M%S)

BASE_BACKUP_PATH="$DATE-backup"
BACKUP_PATH="$BACKUP_PREFIX_PATH/$BASE_BACKUP_PATH"
DB_BACKUP_DIR_NAME="$BASE_BACKUP_PATH/database"

DB_BACKUP_PATH="$BACKUP_PREFIX_PATH/$DB_BACKUP_DIR_NAME"

COMPRESSED_STORAGE_FILE="$BACKUP_PATH/storage.tar.gz"
COMPRESSED_DB_FILE="$BACKUP_PATH/database.tar.gz"

S3_STORAGE_KEY="Test/storage.tar.gz"
S3_DB_KEY="Test/database.tar.gz"

# Create backup directory
mkdir -vp "$BACKUP_PATH"

export MYSQL_CLIENT_CMD
export MYSQLDUMP_CMD

if command -v mariadb >/dev/null 2>&1; then
    MYSQL_CLIENT_CMD="mariadb"
    MYSQLDUMP_CMD="mariadb-dump"
else
    MYSQL_CLIENT_CMD="mysql"
    MYSQLDUMP_CMD="mysqldump"
fi

# Function to handle errors
handle_error() {
    log_message "Error: $1"
    exit 1
}

backup_table() {
    table=$1
    MYSQL_PWD="$DB_PASSWORD" \
    $MYSQLDUMP_CMD -u "$DB_USER" -h "$DB_HOST" -P "$DB_PORT" "$DB_DATABASE" "$table" \
        --single-transaction \
        --skip-lock-tables \
        --no-tablespaces \
        --set-gtid-purged=OFF \
        --skip-comments \
        --skip-dump-date \
        --skip-set-charset \
        --max-allowed-packet=1M \
        --net-buffer-length=8K \
        --skip-add-drop-table \
        --result-file="$DB_BACKUP_PATH/$table.sql" \
        || handle_error "Failed to backup table $table"
}

# Function to backup database
backup_database() {
    log_message "Starting database backup..."
    check_required_env "DB_USER" "DB_PASSWORD" "DB_DATABASE" "DB_HOST" "DB_PORT"
    mkdir -p "$DB_BACKUP_PATH"

    mapfile -t tables < <( MYSQL_PWD="$DB_PASSWORD" $MYSQL_CLIENT_CMD -u "$DB_USER" -h "$DB_HOST" -P "$DB_PORT" -N -e "SHOW TABLES FROM $DB_DATABASE"  --silent )

    # get all the tables in the database and backup each table
    # single table files help with selective restores
    for table in "${tables[@]}"; do
        if [[ "$table" == "tol_LocalStorageDetails" ]]; then
            log_message "Skipping $table for selective backup"
            continue
        fi
        backup_table "$table"
        log_message "Backup of table $table completed"
    done

    log_message "Backing up tol_LocalStorageDetails (last 7 days)"
    backup_table_last_7_days "tol_LocalStorageDetails" "CreatedDate"

    log_message "Compressing db backup to $COMPRESSED_DB_FILE"
    tar -czvf "$COMPRESSED_DB_FILE" --label="Database backup for $DATE taken from $DB_DATABASE" -C "$BACKUP_PREFIX_PATH" "$DB_BACKUP_DIR_NAME" || handle_error "Failed to compress backup"

    compressed_file_size=$(stat -c%s "$COMPRESSED_DB_FILE")

    log_message "Cleaning up temporary directory $DB_BACKUP_PATH"
    rm -vrf "$DB_BACKUP_PATH" || handle_error "Failed to cleanup temporary DB backup directory"

    # if size of compressed file is less than 1MB, delete the backup and exit
    if [ "$compressed_file_size" -lt 1000000 ]; then
        rm -vrf "$BACKUP_PATH" || handle_error "Failed to cleanup DB backup directory"
        handle_error "DB Backup [$compressed_file_size] is less than 1MB."
    fi
}
backup_storage_public() {
    log_message "Starting storage public backup..."
    check_required_env "STORAGE_PUBLIC_PATH"
    # copy all files from the STORAGE_PUBLIC_PATH into BCKUP_STORAGE_PATH, recursively
    tar -czf "$COMPRESSED_STORAGE_FILE" \
        --exclude="logs" \
        --label="Storage backup for $DATE taken from $STORAGE_PUBLIC_PATH" \
        -C "$STORAGE_PUBLIC_PATH" . || handle_error "Failed to backup and compress storage public"

    log_message "Backup and compression of storage public completed"
}

# Function to upload missed backups
upload_file() {
    export FILE_TO_UPLOAD=$1
    export S3_KEY=$2

    check_required_env "AWS_BUCKET" "FILE_TO_UPLOAD" "S3_KEY"

    if [ ! -f "$FILE_TO_UPLOAD" ]; then
        log_message "Error: File to upload does not exist: $FILE_TO_UPLOAD"
        return
    fi

    # get size of file in human readable format
    FILE_SIZE=$(du -h "$FILE_TO_UPLOAD" | cut -f1)
    log_message "Uploading backup: $FILE_TO_UPLOAD to S3: $S3_KEY - Size: $FILE_SIZE"

    # upload the file to S3
    aws s3 cp "$FILE_TO_UPLOAD" "s3://$AWS_BUCKET/$S3_KEY" --metadata "Comment=Backup file for $FILE_TO_UPLOAD"
    if [ $? -eq 0 ]; then
        log_message "Backup uploaded successfully: $FILE_TO_UPLOAD"
        rm -v "$FILE_TO_UPLOAD"
    else
        log_message "Failed to upload backup: $FILE_TO_UPLOAD"
    fi
}

upload_backups() {
    log_message "Initiating upload process ..."
    # look at all the folders in the backup directory, in sorted order
    local backup_dirs_pending
    backup_dirs_pending=$(find "$BACKUP_PREFIX_PATH" -maxdepth 1 -type d | sort -r)
    log_message "Found [$(echo "$backup_dirs_pending" | wc -l)] backup directories to process"

    local curr_backup_dir
    for curr_backup_dir in $backup_dirs_pending ; do
        log_message "Processing backup files from dir: $curr_backup_dir"

        if [ -f "$curr_backup_dir/database.tar.gz" ]; then
            upload_file "$curr_backup_dir/database.tar.gz" "$S3_DB_KEY"
        fi
        if [ -f "$curr_backup_dir/storage.tar.gz" ]; then
            upload_file "$curr_backup_dir/storage.tar.gz" "$S3_STORAGE_KEY"
        fi
        # remove the backup
        log_message "Remaining contents of backup dir: $curr_backup_dir"
        ls -l "$curr_backup_dir"

        # if directory is empty, remove it
        if rmdir -v "$curr_backup_dir"; then
            log_message "Removed empty backup dir: $curr_backup_dir"
        fi
    done

    log_message "Uploading backups completed"
}

check_if_backup_files_remain_after_upload() {
    if [ ! -d "$BACKUP_PREFIX_PATH" ]; then
        log_message "Backup directory $BACKUP_PREFIX_PATH does not exist. Skipping check."
        return
    fi

    files_in_dir=$(find "$BACKUP_PREFIX_PATH" -mindepth 1 -type f | wc -l)

    log_message "Checking if backup files remain after upload..."
    if [ "$files_in_dir" == 0 ]; then
        log_message "No old backup files remain after upload."
        return
    fi

    log_message "[$files_in_dir] backup directories remain after upload. Will be uploaded in the next cycle."
    find "$BACKUP_PREFIX_PATH" -mindepth 1 -type f
}

# set SKIP_UPLOAD and SKIP_DB, if --skip-db or --skip-upload is passed
for arg in "$@"; do
    case "$arg" in
      "--skip-db")
        export SKIP_DB=true
        log_message "Will skip backup"
        ;;
      "--skip-upload")
        export SKIP_UPLOAD=true
        log_message "Will skip upload"
        ;;
      "--skip-storage")
        export SKIP_STORAGE=true
        log_message "Will skip storage backup"
        ;;
    esac
done

# Main execution

# if first param is not "--skip" then run the backup
if [ -z "$SKIP_DB" ]; then
    log_message "Backing up"
    backup_database
else
    log_message "Skipping backup"
fi

if [ -z "$SKIP_STORAGE" ]; then
    log_message "Backing up storage backup"
    backup_storage_public
else
    log_message "Skipping storage backup"
fi

if [ -z "$SKIP_UPLOAD" ]; then
    log_message "Backup will be uploaded to S3."
    upload_backups
else
    log_message "Skipping upload."
fi

check_if_backup_files_remain_after_upload

log_message "Backup process completed."