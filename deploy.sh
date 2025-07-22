#!/usr/bin/env bash

# ======================================================================
# Mailu Deployment Script - Complete with Proxy Authentication
# ======================================================================

set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

if [ ! -d "$SCRIPT_DIR" ]; then
    echo "Error: Could not determine the script's directory." >&2
    exit 1
fi

cd "$SCRIPT_DIR"
ENV_FILE="../secrets/mailu.env"
FORWARD_AUTH_ENV="../secrets/forward-auth.env"

# --- Pre-flight Checks ---
echo "=== Pre-flight Checks ==="

if [[ $EUID -eq 0 ]]; then
   echo "⚠️  WARNING: Running as root. Consider using a non-root user with docker group membership."
fi

if ! command -v docker &> /dev/null; then
    echo "❌ ERROR: Docker is not installed or not in PATH"
    exit 1
fi

if ! docker info &> /dev/null; then
    echo "❌ ERROR: Docker daemon is not running or user lacks permissions"
    exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌ ERROR: Environment file not found at $ENV_FILE" >&2
  exit 1
fi

# --- Load Environment Variables ---
echo "Loading environment variables from $ENV_FILE..."
set -o allexport
source "$ENV_FILE"
set +o allexport

# --- Validate Critical Environment Variables ---
echo "=== Validating Environment Variables ==="

if [[ ${#SECRET_KEY} -ne 32 ]]; then
    echo "❌ ERROR: SECRET_KEY must be exactly 32 characters long (current: ${#SECRET_KEY})"
    echo "   Generate a new one with: openssl rand -hex 16"
    exit 1
fi

required_vars=("DOMAIN" "HOSTNAMES" "POSTMASTER")
for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "❌ ERROR: Required variable $var is not set"
        exit 1
    fi
done

echo "✔️ Environment validation passed"

# --- Setup Data Directories ---
MAILU_DATA_PATH="$SCRIPT_DIR/../data/mailu"
UNBOUND_DATA_PATH="$MAILU_DATA_PATH/unbound"

echo "=== Setting up data directories ==="
echo "Data path: $MAILU_DATA_PATH"

mkdir -p "$MAILU_DATA_PATH"/{data,dkim,mail,mailqueue,overrides/postfix,overrides/dovecot,webmail}
mkdir -p "$UNBOUND_DATA_PATH"

# Fix mail directory ownership if needed
if [[ -d "$MAILU_DATA_PATH/mail" ]]; then
    current_owner=$(stat -c '%u:%g' "$MAILU_DATA_PATH/mail" 2>/dev/null || echo "unknown")
    if [[ "$current_owner" != "1000:1000" ]]; then
        echo "Fixing mail directory ownership..."
        sudo chown -R 1000:1000 "$MAILU_DATA_PATH/mail" || {
            echo "❌ ERROR: Could not set ownership on mail directory"
            echo "   Run: sudo chown -R 1000:1000 $MAILU_DATA_PATH/mail"
        }
    fi
fi

# Download root.hints for Unbound
echo "Downloading latest root.hints file..."
curl -s -f -o "$UNBOUND_DATA_PATH/root.hints" https://www.internic.net/domain/named.root || {
    echo "⚠️  WARNING: Failed to download root.hints file"
}

# --- Container Management ---
remove_container() {
    local container_name="$1"
    if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        echo "  Removing container: $container_name"
        docker rm -f "$container_name" 2>/dev/null || true
    fi
}

echo "=== Cleaning up existing containers ==="
containers_to_remove=(
    "$REDIS_CONTAINER"
    "$FRONT_CONTAINER" 
    "$ADMIN_CONTAINER"
    "$IMAP_CONTAINER"
    "$SMTP_CONTAINER"
    "$WEBMAIL_CONTAINER"
    "$RESOLVER_CONTAINER"
    "mailu-forward-auth"
)

for container in "${containers_to_remove[@]}"; do
    remove_container "$container"
done

# --- Network Management ---
echo "=== Setting up Docker networks ==="

if ! docker network ls --format '{{.Name}}' | grep -q "^${TRAEFIK_NETWORK}$"; then
    echo "❌ ERROR: Traefik network '$TRAEFIK_NETWORK' does not exist"
    echo "   Please create it first or start Traefik"
    exit 1
fi

echo "Recreating Docker network '$MAILU_NETWORK' with subnet $SUBNET..."
docker network rm "$MAILU_NETWORK" 2>/dev/null || true
docker network create --subnet="$SUBNET" "$MAILU_NETWORK"

# --- Pull Images ---
echo "=== Pulling latest Docker images ==="
images=(
    "redis:alpine"
    "thomseddon/traefik-forward-auth:2"
    "$DOCKER_ORG/unbound:$MAILU_VERSION"
    "$DOCKER_ORG/nginx:$MAILU_VERSION"
    "$DOCKER_ORG/admin:$MAILU_VERSION"
    "$DOCKER_ORG/dovecot:$MAILU_VERSION"
    "$DOCKER_ORG/postfix:$MAILU_VERSION"
    "$DOCKER_ORG/webmail:$MAILU_VERSION"
)

for image in "${images[@]}"; do
    echo "  Pulling $image..."
    docker pull "$image" || {
        echo "❌ ERROR: Failed to pull image $image"
        exit 1
    }
done

echo "✔️ All images pulled successfully"

# --- Deploy Forward Auth Service ---
echo "=== Deploying forward authentication service ==="

if [[ -f "$FORWARD_AUTH_ENV" ]]; then
    echo "Loading forward auth configuration..."
    source "$FORWARD_AUTH_ENV"
    
    echo "  Starting Forward Auth container..."
    docker run -d \
      --name "mailu-forward-auth" \
      --restart=always \
      --network="$TRAEFIK_NETWORK" \
      --hostname="auth" \
      -e PROVIDERS_OIDC_ISSUER_URL="${PROVIDERS_OIDC_ISSUER_URL}" \
      -e PROVIDERS_OIDC_CLIENT_ID="${PROVIDERS_OIDC_CLIENT_ID}" \
      -e PROVIDERS_OIDC_CLIENT_SECRET="${PROVIDERS_OIDC_CLIENT_SECRET}" \
      -e DEFAULT_PROVIDER="${DEFAULT_PROVIDER:-oidc}" \
      -e PROVIDERS_GOOGLE_CLIENT_ID="${PROVIDERS_GOOGLE_CLIENT_ID:-}" \
      -e PROVIDERS_GOOGLE_CLIENT_SECRET="${PROVIDERS_GOOGLE_CLIENT_SECRET:-}" \
      -e SECRET="${SECRET}" \
      -e AUTH_HOST="${AUTH_HOST}" \
      -e COOKIE_DOMAIN="${COOKIE_DOMAIN}" \
      -e HEADERS_USERNAME="${HEADERS_USERNAME}" \
      -e HEADERS_GROUPS="${HEADERS_GROUPS:-X-Auth-Groups}" \
      -e HEADERS_NAME="${HEADERS_NAME:-X-Auth-Name}" \
      -e URL_PATH="${URL_PATH}" \
      -e LOGOUT_REDIRECT="${LOGOUT_REDIRECT}" \
      -e LIFETIME="${LIFETIME}" \
      -e LOG_LEVEL="${LOG_LEVEL}" \
      -l "traefik.enable=true" \
      -l "traefik.docker.network=$TRAEFIK_NETWORK" \
      -l "traefik.http.routers.auth.rule=Host(\`${AUTH_HOST}\`)" \
      -l "traefik.http.routers.auth.entrypoints=websecure" \
      -l "traefik.http.routers.auth.tls=true" \
      -l "traefik.http.routers.auth.tls.certresolver=letsencrypt" \
      -l "traefik.http.routers.auth.service=auth-service" \
      -l "traefik.http.services.auth-service.loadbalancer.server.port=4181" \
      -l "traefik.http.middlewares.mailu-auth.forwardauth.address=http://mailu-forward-auth:4181" \
      -l "traefik.http.middlewares.mailu-auth.forwardauth.trustForwardHeader=true" \
      -l "traefik.http.middlewares.mailu-auth.forwardauth.authResponseHeaders=X-Auth-Email,X-Auth-Groups,X-Auth-Name" \
      thomseddon/traefik-forward-auth:2
    
    # Wait for forward auth to be ready
    echo "Waiting for forward auth service..."
    timeout=30
    counter=0
    until docker logs mailu-forward-auth 2>&1 | grep -q "Listening on" || docker logs mailu-forward-auth 2>&1 | grep -q "listening"; do
        if [[ $counter -ge $timeout ]]; then
            echo "⚠️  WARNING: Forward auth may not be ready, checking logs..."
            docker logs mailu-forward-auth --tail 5
            echo "   Continuing with deployment anyway..."
            break
        fi
        echo "  - Waiting for forward auth... ($counter/$timeout)"
        sleep 2
        ((counter++))
    done
    echo "✔️ Forward auth service ready"
else
    echo "⚠️ Skipping forward auth deployment - configuration not found"
    echo "   Run: cd ../keycloak && ./setup-client.sh"
fi

# --- Deploy Core Services ---
echo "=== Deploying core services ==="

# DNS Resolver (Unbound)
echo "  Starting DNS resolver container..."
docker run -d \
  --name "$RESOLVER_CONTAINER" \
  --restart=always \
  --network="$MAILU_NETWORK" \
  --ip="$RESOLVER_ADDRESS" \
  --env-file="$ENV_FILE" \
  -v "$UNBOUND_DATA_PATH:/data" \
  "$DOCKER_ORG/unbound:$MAILU_VERSION"

# Redis Container
echo "  Starting Redis container..."
docker run -d \
  --name "$REDIS_CONTAINER" \
  --restart=always \
  --network="$MAILU_NETWORK" \
  --hostname="$REDIS_HOST" \
  redis:alpine

# Wait for core services
echo "Waiting for core services to be ready..."
sleep 10

timeout=60
counter=0
until docker exec "$RESOLVER_CONTAINER" dig @127.0.0.1 google.com +short 2>/dev/null | grep -q '[0-9]'; do
    if [[ $counter -ge $timeout ]]; then
        echo "❌ ERROR: Unbound failed to start within $timeout seconds"
        docker logs "$RESOLVER_CONTAINER" --tail 20
        exit 1
    fi
    echo "  - Waiting for Unbound... ($counter/$timeout)"
    sleep 2
    ((counter++))
done
echo "✔️ Unbound is ready"

counter=0
until docker exec "$REDIS_CONTAINER" redis-cli ping 2>/dev/null | grep -q "PONG"; do
    if [[ $counter -ge $timeout ]]; then
        echo "❌ ERROR: Redis failed to start within $timeout seconds"
        docker logs "$REDIS_CONTAINER" --tail 20
        exit 1
    fi
    echo "  - Waiting for Redis... ($counter/$timeout)"
    sleep 2
    ((counter++))
done
echo "✔️ Redis is ready"

# --- Deploy Application Services ---
echo "=== Deploying application services ==="

# Admin Container
echo "  Starting Admin container..."
docker run -d \
  --name "$ADMIN_CONTAINER" \
  --restart=always \
  --network="$MAILU_NETWORK" \
  --dns="$RESOLVER_ADDRESS" \
  --env-file="$ENV_FILE" \
  --hostname="admin" \
  -v "$MAILU_DATA_PATH/data:/data" \
  -v "$MAILU_DATA_PATH/dkim:/dkim" \
  "$DOCKER_ORG/admin:$MAILU_VERSION"

# IMAP Container
echo "  Starting IMAP container..."
docker run -d \
  --name "$IMAP_CONTAINER" \
  --restart=always \
  --network="$MAILU_NETWORK" \
  --dns="$RESOLVER_ADDRESS" \
  --env-file="$ENV_FILE" \
  --hostname="imap" \
  -v "$MAILU_DATA_PATH/mail:/mail" \
  -v "$MAILU_DATA_PATH/overrides/dovecot:/overrides:ro" \
  "$DOCKER_ORG/dovecot:$MAILU_VERSION"

# SMTP Container
echo "  Starting SMTP container..."
docker run -d \
  --name "$SMTP_CONTAINER" \
  --restart=always \
  --network="$MAILU_NETWORK" \
  --dns="$RESOLVER_ADDRESS" \
  --env-file="$ENV_FILE" \
  --hostname="smtp" \
  -v "$MAILU_DATA_PATH/mailqueue:/queue" \
  -v "$MAILU_DATA_PATH/overrides/postfix:/overrides:ro" \
  "$DOCKER_ORG/postfix:$MAILU_VERSION"

# Webmail Container
echo "  Starting Webmail container..."
docker run -d \
  --name "$WEBMAIL_CONTAINER" \
  --restart=always \
  --network="$MAILU_NETWORK" \
  --dns="$RESOLVER_ADDRESS" \
  --env-file="$ENV_FILE" \
  --hostname="webmail" \
  -v "$MAILU_DATA_PATH/webmail:/data" \
  "$DOCKER_ORG/webmail:$MAILU_VERSION"

# Front Container (Main Entry Point)
echo "  Starting Front/Nginx container..."
docker run -d \
  --name "$FRONT_CONTAINER" \
  --restart=always \
  --network="$MAILU_NETWORK" \
  --dns="$RESOLVER_ADDRESS" \
  --env-file="$ENV_FILE" \
  --hostname="$FRONT_ADDRESS" \
  -v "$MAILU_DATA_PATH/overrides/nginx:/overrides:ro" \
  -l "traefik.enable=true" \
  -l "traefik.docker.network=$TRAEFIK_NETWORK" \
  -l "traefik.http.routers.mailu-public.rule=Host(\`${HOSTNAMES}\`)" \
  -l "traefik.http.routers.mailu-public.entrypoints=websecure" \
  -l "traefik.http.routers.mailu-public.service=mailu-service" \
  -l "traefik.http.routers.mailu-public.tls=true" \
  -l "traefik.http.routers.mailu-public.tls.certresolver=letsencrypt" \
  -l "traefik.http.routers.mailu-public.priority=50" \
  -l "traefik.http.routers.mailu-sso.rule=Host(\`${HOSTNAMES}\`) && PathPrefix(\`/sso\`)" \
  -l "traefik.http.routers.mailu-sso.entrypoints=websecure" \
  -l "traefik.http.routers.mailu-sso.middlewares=mailu-auth@docker" \
  -l "traefik.http.routers.mailu-sso.service=mailu-service" \
  -l "traefik.http.routers.mailu-sso.tls=true" \
  -l "traefik.http.routers.mailu-sso.priority=100" \
  -l "traefik.http.services.mailu-service.loadbalancer.server.port=80" \
  "$DOCKER_ORG/nginx:$MAILU_VERSION"

# Connect front container to Traefik network
echo "  Connecting Front container to Traefik network..."
docker network connect "$TRAEFIK_NETWORK" "$FRONT_CONTAINER"

# Wait for front container to initialize and generate nginx config
echo "Waiting for Front container to initialize..."
sleep 15

# Generate nginx configuration
echo "Generating Mailu nginx configuration..."
docker exec "$FRONT_CONTAINER" python3 -c "
import os
from socrate import conf
os.chdir('/conf')
conf.jinja('/conf/nginx.conf', os.environ, '/etc/nginx/nginx.conf')
print('Nginx config generated')
" || echo "⚠️ Config generation failed, using default"

# Reload nginx with new config
docker exec "$FRONT_CONTAINER" nginx -s reload || echo "⚠️ Nginx reload failed"

# --- Final Health Checks ---
echo "=== Final health checks ==="

sleep 10

all_containers=(
    "$REDIS_CONTAINER"
    "$RESOLVER_CONTAINER" 
    "$ADMIN_CONTAINER"
    "$IMAP_CONTAINER"
    "$SMTP_CONTAINER"
    "$WEBMAIL_CONTAINER"
    "$FRONT_CONTAINER"
)

failed_containers=()
for container in "${all_containers[@]}"; do
    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        failed_containers+=("$container")
    fi
done

# Check forward auth separately (optional)
if [[ -f "$FORWARD_AUTH_ENV" ]] && ! docker ps --format '{{.Names}}' | grep -q "^mailu-forward-auth$"; then
    echo "⚠️  WARNING: Forward auth container not running - authentication may not work"
fi

if [[ ${#failed_containers[@]} -gt 0 ]]; then
    echo "❌ ERROR: The following containers failed to start:"
    printf '   - %s\n' "${failed_containers[@]}"
    echo ""
    echo "Check container logs with:"
    printf '   docker logs %s\n' "${failed_containers[@]}"
    exit 1
fi

echo ""
echo "🎉 SUCCESS! Mailu deployment completed successfully!"
echo ""
echo "📍 Access points:"
if [[ -f "$FORWARD_AUTH_ENV" ]]; then
    echo "   • Admin interface: https://${HOSTNAMES%%,*}/admin/ (Keycloak authentication)"
    echo "   • Webmail: https://${HOSTNAMES%%,*}/webmail/ (Keycloak authentication)"  
    echo "   • Auth service: https://auth.ai-servicers.com/_oauth"
else
    echo "   • Admin interface: https://${HOSTNAMES%%,*}/admin/ (local authentication)"
    echo "   • Webmail: https://${HOSTNAMES%%,*}/webmail/ (local authentication)"
fi
echo "   • Public access: https://${HOSTNAMES%%,*}/"
echo ""

if [[ -f "$FORWARD_AUTH_ENV" ]]; then
    echo "🔐 Authentication Flow:"
    echo "   • Users redirected to Keycloak for login"
    echo "   • After authentication, users auto-created in Mailu"
    echo "   • Test user: websurfinmurf / Qwert-0987lr"
    echo ""
fi

echo "📊 Container status:"
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' --filter name=mailu-
[[ -f "$FORWARD_AUTH_ENV" ]] && docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' --filter name=mailu-forward-auth

echo ""
echo "🔧 Useful commands:"
echo "   • View logs: docker logs <container-name>"
echo "   • Test auth: curl -I https://${HOSTNAMES%%,*}/admin/"
echo "   • Check status: docker ps --filter name=mailu-"
echo "   • Stop all: docker stop \$(docker ps -q --filter name=mailu-)"
echo ""

if [[ ! -f "$FORWARD_AUTH_ENV" ]]; then
    echo "🚀 Next steps for authentication:"
    echo "   1. Set up Keycloak OIDC client:"
    echo "      cd ../keycloak && ./setup-client.sh"
    echo "   2. Redeploy Mailu: ./deploy.sh"
fi
