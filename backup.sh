#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Mailu Backup Script
# ==============================================================================
#
# Description:
#   Creates an encrypted backup of the Mailu database and data volume.
#
# ==============================================================================

# --- Load Environment Variables ---
source "$(dirname "$0")/mailu.env"

# --- Backup Directory Setup ---
DAY=$(date +%Y-%m-%d)
BACKUP_FILE="$BACKUP_BASE/mailu-$DAY.tar.gz.gpg"

# Create the backup directory if it doesn't exist
mkdir -p "$BACKUP_BASE"

# --- Temporary Workspace ---
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# --- Dump PostgreSQL Database ---
echo "Dumping PostgreSQL database..."
docker exec -e PGPASSWORD="$DB_PASSWORD" mailu_db_1 \
  pg_dump -U "$DB_USER" -d "$DB_NAME" \
  > "$TMPDIR/db.sql"

# --- Archive Mailu Data Volume ---
echo "Archiving Mailu data volume..."
docker run --rm \
  -v mailu_data:/data \
  -v "$TMPDIR":/backup \
  busybox \
  tar -czf /backup/data.tar.gz -C /data .

# --- Combine and Encrypt ---
echo "Creating and encrypting the combined backup archive..."
tar -czf - -C "$TMPDIR" db.sql data.tar.gz | \
  gpg --batch --yes --output "$BACKUP_FILE" \
      --encrypt --recipient "$GPG_RECIPIENT"

# --- Cleanup and Completion ---
echo
echo "✔️ Backup completed and encrypted to: $BACKUP_FILE"
