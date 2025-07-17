#!/usr/bin/env bash

# ======================================================================
# Mailu Deployment Script (Final Verified Version)
# ======================================================================
# Deploys Mailu with the front-end handling all web routing and
# Traefik handling SSL termination and mail protocol passthrough.

# --- Setup and Pre-flight Checks ---
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

if [ ! -d "$SCRIPT_DIR" ]; then
    echo "Error: Could not determine the script's directory." >&2
    exit 1
fi

cd "$SCRIPT_DIR"

ENV_FILE="../secrets/mailu.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: Environment file not found at $ENV_FILE" >&2
  echo "Please ensure your mailu.env file is located in the '../secrets' directory." >&2
  exit 1
fi

# --- Load All Variables from Environment File ---
echo "Loading environment variables from $ENV_FILE..."
set -o allexport
source "$ENV_FILE"
set +o allexport

# --- Define Paths and Create Directories ---
MAILU_DATA_PATH="$SCRIPT_DIR/../data/mailu"
echo "Setting up network and directories in $MAILU_DATA_PATH..."
docker network create "$MAILU_NETWORK" 2>/dev/null || true
mkdir -p "$MAILU_DATA_PATH"/{data,dkim,mail,mailqueue,overrides/postfix,overrides/dovecot,webmail}

# --- Service Deployment ---
remove_container() {
  local container_name=$1
  echo "Removing existing container: $container_name..."
  docker rm -f "$container_name" 2>/dev/null || true
}

echo "Removing all existing Mailu containers..."
remove_container "$REDIS_CONTAINER"
remove_container "$FRONT_CONTAINER"
remove_container "$ADMIN_CONTAINER"
remove_container "$IMAP_CONTAINER"
remove_container "$SMTP_CONTAINER"
remove_container "$WEBMAIL_CONTAINER"

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

# Front Container (The main entrypoint for Traefik)
docker run -d \
  --name "$FRONT_CONTAINER" \
  --restart=always \
  --network="$MAILU_NETWORK" \
  --network="$TRAEFIK_NETWORK" \
  --env-file="$ENV_FILE" \
  -v "$MAILU_DATA_PATH/overrides/nginx:/overrides:ro" \
  -v "/home/websurfinmurf/projects/traefik/certs/ai-servicers.com:/certs:ro" \
  -l "traefik.enable=true" \
  -l "traefik.docker.network=$TRAEFIK_NETWORK" \
  -l "traefik.http.routers.mailu-http.rule=Host(\`${HOSTNAMES}\`)" \
  -l "traefik.http.routers.mailu-http.entrypoints=web" \
  -l "traefik.http.routers.mailu-http.middlewares=https-redirect@file" \
  -l "traefik.http.routers.mailu-https.rule=Host(\`${HOSTNAMES}\`)" \
  -l "traefik.http.routers.mailu-https.entrypoints=websecure" \
  -l "traefik.http.routers.mailu-https.service=mailu-service" \
  --label "traefik.http.routers.mailu-https.tls=true" \
  --label "traefik.http.routers.mailu-https.tls.certresolver=letsencrypt" \
  --label "traefik.http.routers.mailu-https.tls.domains[0].main=ai-servicers.com" \
  --label "traefik.http.routers.mailu-https.tls.domains[0].sans=*.ai-servicers.com" \
  -l "traefik.http.services.mailu-service.loadbalancer.server.port=80" \
  -l "traefik.tcp.routers.smtp.rule=HostSNI(\`*\`)" \
  -l "traefik.tcp.routers.smtp.entrypoints=smtp" \
  -l "traefik.tcp.routers.smtp.service=smtp-service" \
  -l "traefik.tcp.services.smtp-service.loadbalancer.server.port=25" \
  -l "traefik.tcp.routers.smtps.rule=HostSNI(\`*\`)" \
  -l "traefik.tcp.routers.smtps.entrypoints=smtps" \
  -l "traefik.tcp.routers.smtps.service=smtps-service" \
  -l "traefik.tcp.services.smtps-service.loadbalancer.server.port=465" \
  -l "traefik.tcp.routers.smtps.tls.passthrough=true" \
  -l "traefik.tcp.routers.submission.rule=HostSNI(\`*\`)" \
  -l "traefik.tcp.routers.submission.entrypoints=submission" \
  -l "traefik.tcp.routers.submission.service=submission-service" \
  -l "traefik.tcp.services.submission-service.loadbalancer.server.port=587" \
  -l "traefik.tcp.routers.imaps.rule=HostSNI(\`*\`)" \
  -l "traefik.tcp.routers.imaps.entrypoints=imaps" \
  -l "traefik.tcp.routers.imaps.service=imaps-service" \
  -l "traefik.tcp.services.imaps-service.loadbalancer.server.port=993" \
  -l "traefik.tcp.routers.imaps.tls.passthrough=true" \
  "$DOCKER_ORG/nginx:$MAILU_VERSION"

# Admin Container (No direct Traefik labels needed)
docker run -d \
  --name "$ADMIN_CONTAINER" \
  --restart=always \
  --network="$MAILU_NETWORK" \
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
  -v "$MAILU_DATA_PATH/mail:/mail" \
  -v "$MAILU_DATA_PATH/overrides/dovecot:/overrides:ro" \
  "$DOCKER_ORG/dovecot:$MAILU_VERSION"

# SMTP Container
docker run -d \
  --name "$SMTP_CONTAINER" \
  --restart=always \
  --network="$MAILU_NETWORK" \
  --env-file="$ENV_FILE" \
  -v "$MAILU_DATA_PATH/mailqueue:/queue" \
  -v "$MAILU_DATA_PATH/overrides/postfix:/overrides:ro" \
  "$DOCKER_ORG/postfix:$MAILU_VERSION"

# Webmail Container
docker run -d \
  --name "$WEBMAIL_CONTAINER" \
  --restart=always \
  --network="$MAILU_NETWORK" \
  --env-file="$ENV_FILE" \
  -v "$MAILU_DATA_PATH/webmail:/data" \
  "$DOCKER_ORG/webmail:$MAILU_VERSION"

echo
echo "✔️ Mailu deployment is complete!"
echo "   All services started using individual 'docker run' commands."
echo "   Access via https://${HOSTNAMES%%,*}"
