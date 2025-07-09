#!/usr/bin/env bash

# ======================================================================
# Mailu Deployment Script (Final Corrected Version)
# ======================================================================
# Deploys Mailu using certificates provided by an external source (Traefik).
# This version includes all necessary fixes for a stable deployment.

# --- Setup and Pre-flight Checks ---
set -euo pipefail
# Use a more robust method to find the script directory
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

# Check if SCRIPT_DIR is a valid directory
if [ ! -d "$SCRIPT_DIR" ]; then
    echo "Error: Could not determine the script's directory."
    echo "Please run the script from its containing folder."
    exit 1
fi

cd "$SCRIPT_DIR"

# Path to the environment file
ENV_FILE="../secrets/mailu.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: Environment file not found at $ENV_FILE"
  echo "Please ensure your mailu.env file is located in the '../secrets' directory."
  exit 1
fi

# --- Load All Variables from Environment File ---
echo "Loading environment variables from $ENV_FILE..."
set -o allexport
source "$ENV_FILE"
set +o allexport

# --- Define the data directory inside the project folder ---
MAILU_DATA_PATH="$SCRIPT_DIR/../data/mailu"

# --- Create Docker Network and User-Owned Directories ---
echo "Setting up network and directories in $MAILU_DATA_PATH..."
docker network create "$MAILU_NETWORK" 2>/dev/null || true
mkdir -p "$MAILU_DATA_PATH"/{data,dkim,mail,mailqueue,overrides/postfix,overrides/dovecot,webmail}

# --- Service Deployment ---

# Function to stop and remove a container if it exists
remove_container() {
  local container_name=$1
  echo "Removing existing container: $container_name..."
  docker rm -f "$container_name" 2>/dev/null || true
}

# 1. Remove all existing containers first
remove_container "$REDIS_CONTAINER"
remove_container "$FRONT_CONTAINER"
remove_container "$ADMIN_CONTAINER"
remove_container "$IMAP_CONTAINER"
remove_container "$SMTP_CONTAINER"
remove_container "$WEBMAIL_CONTAINER"

# 2. Deploy Services
echo "Pulling latest images..."
docker pull redis:alpine
docker pull "$DOCKER_ORG/nginx:$MAILU_VERSION"
docker pull "$DOCKER_ORG/admin:$MAILU_VERSION"
docker pull "$DOCKER_ORG/dovecot:$MAILU_VERSION"
docker pull "$DOCKER_ORG/postfix:$MAILU_VERSION"
docker pull "$DOCKER_ORG/webmail:$MAILU_VERSION"


echo "Deploying containers..."

# Redis Container
docker run -d \
  --name "$REDIS_CONTAINER" \
  --restart=always \
  --network="$MAILU_NETWORK" \
  --network-alias redis \
  redis:alpine

# Front Container (Connected to Traefik)
docker run -d \
  --name "$FRONT_CONTAINER" \
  --restart=always \
  --network="$MAILU_NETWORK" \
  --network="$TRAEFIK_NETWORK" \
  --env-file="$ENV_FILE" \
  -v "$SCRIPT_DIR/../traefik/certs/mailu.ai-servicers.com":/certs:ro \
  -v "$MAILU_DATA_PATH/overrides/nginx":/overrides:ro \
  -l "traefik.enable=true" \
  -l "traefik.docker.network=$TRAEFIK_NETWORK" \
  -l "traefik.http.routers.mailu-http.rule=Host(\`${HOSTNAMES}\`)" \
  -l "traefik.http.routers.mailu-http.entrypoints=web" \
  -l "traefik.http.routers.mailu-http.middlewares=https-redirect@file" \
  -l "traefik.http.routers.mailu-https.rule=Host(\`${HOSTNAMES}\`)" \
  -l "traefik.http.routers.mailu-https.entrypoints=websecure" \
  -l "traefik.http.routers.mailu-https.tls=true" \
  -l "traefik.http.routers.mailu-https.tls.certresolver=letsencrypt" \
  -l "traefik.http.services.mailu-web.loadbalancer.server.port=80" \
  -l "traefik.tcp.routers.smtp.rule=HostSNI(\`*\`)" \
  -l "traefik.tcp.routers.smtp.entrypoints=smtp" \
  -l "traefik.tcp.services.smtp.loadbalancer.server.port=25" \
  -l "traefik.tcp.routers.smtps.rule=HostSNI(\`*\`)" \
  -l "traefik.tcp.routers.smtps.entrypoints=smtps" \
  -l "traefik.tcp.services.smtps.loadbalancer.server.port=465" \
  -l "traefik.tcp.routers.smtps.tls.passthrough=true" \
  -l "traefik.tcp.routers.submission.rule=HostSNI(\`*\`)" \
  -l "traefik.tcp.routers.submission.entrypoints=submission" \
  -l "traefik.tcp.services.submission.loadbalancer.server.port=587" \
  -l "traefik.tcp.routers.imaps.rule=HostSNI(\`*\`)" \
  -l "traefik.tcp.routers.imaps.entrypoints=imaps" \
  -l "traefik.tcp.services.imaps.loadbalancer.server.port=993" \
  -l "traefik.tcp.routers.imaps.tls.passthrough=true" \
  "$DOCKER_ORG/nginx:$MAILU_VERSION"

# Admin Container
docker run -d \
  --name "$ADMIN_CONTAINER" \
  --restart=always \
  --network="$MAILU_NETWORK" \
  --dns=1.1.1.1 \
  --env-file="$ENV_FILE" \
  -v "$MAILU_DATA_PATH/data":/data \
  -v "$MAILU_DATA_PATH/dkim":/dkim \
  "$DOCKER_ORG/admin:$MAILU_VERSION"

# IMAP Container
docker run -d \
  --name "$IMAP_CONTAINER" \
  --restart=always \
  --network="$MAILU_NETWORK" \
  --env-file="$ENV_FILE" \
  -v "$MAILU_DATA_PATH/mail":/mail \
  -v "$MAILU_DATA_PATH/overrides/dovecot":/overrides:ro \
  "$DOCKER_ORG/dovecot:$MAILU_VERSION"

# SMTP Container
docker run -d \
  --name "$SMTP_CONTAINER" \
  --restart=always \
  --network="$MAILU_NETWORK" \
  --env-file="$ENV_FILE" \
  -v "$MAILU_DATA_PATH/mailqueue":/queue \
  -v "$MAILU_DATA_PATH/overrides/postfix":/overrides:ro \
  "$DOCKER_ORG/postfix:$MAILU_VERSION"

# Webmail Container
docker run -d \
  --name "$WEBMAIL_CONTAINER" \
  --restart=always \
  --network="$MAILU_NETWORK" \
  --env-file="$ENV_FILE" \
  -v "$MAILU_DATA_PATH/webmail":/data \
  "$DOCKER_ORG/webmail:$MAILU_VERSION"

echo
echo "✔️ Mailu deployment is complete!"
echo "   All services started using individual 'docker run' commands."
echo "   Access via https://${HOSTNAMES%%,*}"
