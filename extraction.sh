#!/bin/bash
set -e

# === Credentials ===
S3_BUCKET="backup-from-production"
S3_KEY="database.tar.gz"

STAGE_HOST="devteststage.cojoh3xvwxbb.us-east-2.rds.amazonaws.com"
DB_PORT=3306
STAGE_USER="testuser"
STAGE_PASS="testpnut"
STAGE_DB="theomnilife_test"

# === DIRECTORIES ===
WORK_DIR="./Dumps"
ARCHIVE_PATH="$WORK_DIR/database.tar.gz"
EXTRACT_DIR="$WORK_DIR/extracted_sqls"
mkdir -p "$EXTRACT_DIR"

echo "[1/4] Downloading database.tar.gz from S3..."
aws s3 cp "s3://$S3_BUCKET/$S3_KEY" "$ARCHIVE_PATH"
echo "✅ Download complete."

echo "[2/4] Extracting SQL files from archive..."
tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"
echo "✅ Extraction complete."
echo "------------------------------------------------------------"

echo "[3/4] Dropping all tables from staging database..."
echo "Droppin database from staging database and creating new: $STAGE_DB"

mysql_base=(mysql -h "$STAGE_HOST" -P "$DB_PORT" -u "$STAGE_USER" -p"$STAGE_PASS")
echo "Dropping and recreating database: $STAGE_DB"

"${mysql_base[@]}" -e "DROP DATABASE IF EXISTS \`$STAGE_DB\`;" || {
  echo "Failed to drop database: $STAGE_DB"
  exit 1
}

"${mysql_base[@]}" -e "CREATE DATABASE \`$STAGE_DB\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || {
  echo "Failed to create database: $STAGE_DB"
  exit 1
}

"${mysql_base[@]}" -e "GRANT ALL PRIVILEGES ON \`$STAGE_DB\`.* TO '$STAGE_USER'@'%';" || {
  echo "⚠️ Warning: Could not re-grant permissions to $STAGE_USER"
}

echo "Recreated the database: STAGE_DB"
echo "------------------------------------------------------------"

echo "[4/4] Importing SQL files into staging database..."

latest_dir=$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)

if [ -z "$latest_dir" ]; then
  echo "No extracted timestamp folder found in $EXTRACT_DIR. Aborting!"
  exit 1
fi

sql_dir="$latest_dir/database"

if [ ! -d "$sql_dir" ]; then
  echo "Expected 'database' directory not found in $latest_dir. Aborting!"
  exit 1
fi

# 👉 Populate the array with all .sql files
sql_files=("$sql_dir"/*.sql)

# Import all SQL files (schema + data)
for sql_file in "${sql_files[@]}"; do
  echo "Importing $(basename "$sql_file")"
  sed -E '/SET @@GLOBAL.GTID_PURGED/d; s/DEFINER=`[^`]+`@`[^`]+`//g' "$sql_file" | \
    mysql -h "$STAGE_HOST" -P "$DB_PORT" -u "$STAGE_USER" -p"$STAGE_PASS" "$STAGE_DB"
done

echo "✅ All SQL files imported into staging."
echo "------------------------------------------------------------"
echo "✅ Full migration from S3 archive to Staging completed successfully!"