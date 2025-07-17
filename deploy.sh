#!/usr/bin/env bash

# ======================================================================
# Mailu Deployment Script (Final Verified Version with Static IP Resolver)
# ======================================================================
# Deploys Mailu with a static IP for the unbound DNS resolver to solve
# the DNSSEC validation issue permanently and reliably.

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
  exit 1
fi

# --- Load All Variables from Environment File ---
echo "Loading environment variables from $ENV_FILE..."
set -o allexport
source "$ENV_FILE"
set +o allexport

# --- Define Paths and Create Directories ---
MAILU_DATA_PATH="$SCRIPT_DIR/../data/mailu"
UNBOUND_DATA_PATH="$MAILU_DATA_PATH/unbound"
UNBOUND_CONF_DEST_PATH="$UNBOUND_DATA_PATH/unbound.conf"
LOCAL_UNBOUND_CONF_SRC="$SCRIPT_DIR/unbound.conf"

echo "Setting up data directories in $MAILU_DATA_PATH..."
mkdir -p "$MAILU_DATA_PATH"/{data,dkim,mail,mailqueue,overrides/postfix,overrides/dovecot,webmail}
mkdir -p "$UNBOUND_DATA_PATH"

# --- Copy the local Unbound config file to the data directory ---
echo "Looking for local unbound.conf..."
if [ ! -f "$LOCAL_UNBOUND_CONF_SRC" ]; then
    echo "❌ ERROR: unbound.conf not found at $LOCAL_UNBOUND_CONF_SRC"
    echo "   Please create it in the same directory as deploy.sh before running."
    exit 1
fi

echo "Copying local unbound.conf to data directory..."
cp "$LOCAL_UNBOUND_CONF_SRC" "$UNBOUND_CONF_DEST_PATH"


# --- Service Deployment ---
remove_container() {
  docker rm -f "$1" 2>/dev/null || true
}

echo "Removing all existing Mailu containers..."
remove_container "$REDIS_CONTAINER"
remove_container "$FRONT_CONTAINER"
remove_container "$ADMIN_CONTAINER"
remove_container "$IMAP_CONTAINER"
remove_container "$SMTP_CONTAINER"
remove_container "$WEBMAIL_CONTAINER"
remove_container "$RESOLVER_CONTAINER"

# --- Recreate the Network ---
echo "Recreating Docker network '$MAILU_NETWORK' to ensure correct subnet..."
docker network rm "$MAILU_NETWORK" 2>/dev/null || true
docker network create --subnet="$SUBNET" "$MAILU_NETWORK"

echo "Pulling latest images..."
docker pull redis:alpine
docker pull "$DOCKER_ORG/unbound:$MAILU_VERSION"
docker pull "$DOCKER_ORG/nginx:$MAILU_VERSION"
docker pull "$DOCKER_ORG/admin:$MAILU_VERSION"
docker pull "$DOCKER_ORG/dovecot:$MAILU_VERSION"
docker pull "$DOCKER_ORG/postfix:$MAILU_VERSION"
docker pull "$DOCKER_ORG/webmail:$MAILU_VERSION"

echo "Deploying core services..."

# DNS Resolver (Unbound) with a Static IP
docker run -d \
  --name "$RESOLVER_CONTAINER" \
  --restart=always \
  --network="$MAILU_NETWORK" \
  --ip="$RESOLVER_ADDRESS" \
  -v "$UNBOUND_CONF_DEST_PATH:/etc/unbound/unbound.conf:ro" \
  -v "$UNBOUND_DATA_PATH:/etc/unbound" \
  "$DOCKER_ORG/unbound:$MAILU_VERSION"

# Redis Container
docker run -d \
  --name "$REDIS_CONTAINER" \
  --restart=always \
  --network="$MAILU_NETWORK" \
  redis:alpine

# --- Health Checks ---
echo "Waiting for Unbound DNS resolver to be ready..."
# We unset LD_PRELOAD here to avoid the harmless error inside the container
until LD_PRELOAD="" docker exec "$RESOLVER_CONTAINER" dig @127.0.0.1 google.com +short | grep -q '[0-9]'; do
  echo "  - Unbound not ready yet, waiting 2 seconds..."
  sleep 2
done
echo "✔️ Unbound is ready."

echo "Waiting for Redis to be ready..."
until LD_PRELOAD="" docker exec "$REDIS_CONTAINER" redis-cli ping | grep -q "PONG"; do
  echo "  - Redis not ready yet, waiting 2 seconds..."
  sleep 2
done
echo "✔️ Redis is ready."


echo "Deploying remaining Mailu services..."

# Admin Container (Points to the Unbound resolver's static IP)
docker run -d \
  --name "$ADMIN_CONTAINER" \
  --restart=always \
  --network="$MAILU_NETWORK" \
  --dns="$RESOLVER_ADDRESS" \
  --env-file="$ENV_FILE" \
  -v "$MAILU_DATA_PATH/data":/data \
  -v "$MAILU_DATA_PATH/dkim":/dkim \
  "$DOCKER_ORG/admin:$MAILU_VERSION"

# Front Container (The main entrypoint for Traefik)
docker run -d \
  --name "$FRONT_CONTAINER" \
  --restart=always \
  --network="$MAILU_NETWORK" \
  --network="$TRAEFIK_NETWORK" \
  --dns="$RESOLVER_ADDRESS" \
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

# IMAP Container
docker run -d \
  --name "$IMAP_CONTAINER" \
  --restart=always \
  --network="$MAILU_NETWORK" \
  --dns="$RESOLVER_ADDRESS" \
  --env-file="$ENV_FILE" \
  -v "$MAILU_DATA_PATH/mail:/mail" \
  -v "$MAILU_DATA_PATH/overrides/dovecot:/overrides:ro" \
  "$DOCKER_ORG/dovecot:$MAILU_VERSION"

# SMTP Container
docker run -d \
  --name "$SMTP_CONTAINER" \
  --restart=always \
  --network="$MAILU_NETWORK" \
  --dns="$RESOLVER_ADDRESS" \
  --env-file="$ENV_FILE" \
  -v "$MAILU_DATA_PATH/mailqueue:/queue" \
  -v "$MAILU_DATA_PATH/overrides/postfix:/overrides:ro" \
  "$DOCKER_ORG/postfix:$MAILU_VERSION"

# Webmail Container
docker run -d \
  --name "$WEBMAIL_CONTAINER" \
  --restart=always \
  --network="$MAILU_NETWORK" \
  --dns="$RESOLVER_ADDRESS" \
  --env-file="$ENV_FILE" \
  -v "$MAILU_DATA_PATH/webmail:/data" \
  "$DOCKER_ORG/webmail:$MAILU_VERSION"

echo
echo "✔️ Mailu deployment is complete!"
echo "   All services started using individual 'docker run' commands."
echo "   Access via https://${HOSTNAMES%%,*}"
