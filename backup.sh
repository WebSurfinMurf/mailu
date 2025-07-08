#!/usr/bin/env bash

# ======================================================================
# Mailu Backup Script (for docker run methodology)
# ======================================================================
# Creates an encrypted backup of the Mailu data volumes.
# This version works with manually named containers.

# --- Setup and Pre-flight Checks ---
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE="mailu.env" # Assumes mailu.env is in the same directory

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: Environment file not found at $SCRIPT_DIR/$ENV_FILE"
  exit 1
fi

# --- Load All Variables from Environment File ---
echo "Loading environment variables from $ENV_FILE..."
set -o allexport
source "$ENV_FILE"
set +o allexport

# --- Backup Directory Setup ---
DAY=$(date +%Y-%m-%d)
BACKUP_FILE="$BACKUP_BASE/mailu-backup-$DAY.tar.gz.gpg"

# Check if GPG_RECIPIENT is set
if [[ -z "${GPG_RECIPIENT}" ]]; then
  echo "❌ Error: GPG_RECIPIENT is not set in mailu.env. Cannot create encrypted backup."
  exit 1
fi

# Create the backup directory if it doesn't exist
mkdir -p "$BACKUP_BASE
