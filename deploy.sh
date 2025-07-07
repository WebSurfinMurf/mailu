#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Mailu Deployment Script
# ==============================================================================
#
# Description:
#   Deploys Mailu with all necessary components, including networking
#   and volumes.
#
# ==============================================================================

# --- Load Environment Variables ---
source "$(dirname "$0")/mailu.env"

# --- Docker Network and Volume Setup ---
NETWORK="mailu-network"
DB_VOLUME="mailu_db_data"
DATA_VOLUME="mailu_data"

# Ensure the Docker network exists
if ! docker network ls --format '{{.Name}}' | grep -qx "${NETWORK}"; then
  echo "Creating Docker network: ${NETWORK}..."
  docker network create "${NETWORK}"
fi

# Ensure Docker volumes exist
for vol in "${DB_VOLUME}" "${DATA_VOLUME}"; do
  if ! docker volume ls --format '{{.Name}}' | grep -qx "${vol}"; then
    echo "Creating Docker volume: ${vol}..."
    docker volume create "${vol}"
  fi
done

# --- Mailu Docker Compose Deployment ---
echo "Deploying Mailu services..."
docker-compose -p mailu up -d

echo
echo "✔️ Mailu deployment is complete!"
echo "   Admin interface: https://${HOSTNAMES%%,*}"
echo "   Webmail: https://${HOSTNAMES%%,*}/webmail"
