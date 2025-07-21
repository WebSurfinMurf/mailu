#!/usr/bin/env bash

# ======================================================================
# Mailu Deployment Script - Proxy Authentication Integration
# ======================================================================

set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

if [ ! -d "$SCRIPT_DIR" ]; then
    echo "Error: Could not determine the script's directory." >&2
    exit 1
fi

cd "$SCRIPT_DIR"
ENV_FILE="../secrets/mailu.env"

# --- Pre-flight Checks ---
echo "=== Pre-flight Checks ==="

# Check if running as root (not recommended for Docker)
if [[ $EUID -eq 0 ]]; then
   echo "⚠️  WARNING: Running as root. Consider using a non-root user with docker group membership."
fi

# Check Docker availability
if ! command -v docker &> /dev/null; then
    echo "❌ ERROR: Docker is not installed or not in PATH"
    exit 1
fi

# Check if Docker daemon is running
if ! docker info &> /dev/null; then
    echo "❌ ERROR: Docker daemon is not running or user lacks permissions"
    exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌ ERROR: Environment file not found at $ENV_FILE" >&2
  exit 1
fi

# --- Load All Variables from Environment File ---
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

if [[ -z "${DOMAIN:-}" ]]; then
    echo "❌ ERROR: DOMAIN is required"
    exit 1
fi

if [[ -z "${HOSTNAMES:-}" ]]; then
    echo "❌ ERROR: HOSTNAMES is required"
    exit 1
fi

if [[ -z "${POSTMASTER:-}" ]]; then
    echo "❌ ERROR: POSTMASTER is required"
    exit 1
fi

# Validate proxy auth settings
if [[ -z "${PROXY_AUTH_WHITELIST:-}" ]]; then
    echo "❌ ERROR: PROXY_AUTH_WHITELIST is required for proxy authentication"
    exit 1
fi

if [[ -z "${PROXY_AUTH_HEADER:-}" ]]; then
    echo "❌ ERROR: PROXY_AUTH_HEADER is required for proxy authentication"
    exit 1
fi

echo "✔️ Environment validation passed"

# --- Define Paths and Create Directories ---
MAILU_DATA_PATH="$SCRIPT_DIR/../data/mailu"
UNBOUND_DATA_PATH="$MAILU_DATA_PATH/unbound"
ROOT_HINTS_DEST_PATH="$UNBOUND_DATA_PATH/root.hints"

echo "=== Setting up data directories ==="
echo "Data path: $MAILU_DATA_PATH"

# Create directories with proper permissions
mkdir -p "$MAILU_DATA_PATH"/{data,dkim,mail,mailqueue,overrides/postfix,overrides/dovecot,webmail}
mkdir -p "$UNBOUND_DATA_PATH"

# Check and fix mail directory ownership only if needed
if [[ -d "$MAILU_DATA_PATH/mail" ]]; then
    # Check current ownership
    current_owner=$(stat -c '%u:%g' "$MAILU_DATA_PATH/mail" 2>/dev/null || echo "unknown")
    
    if [[ "$current_owner" != "1000:1000" ]]; then
        echo "Mail directory ownership needs to be fixed (current: $current_owner, needed: 1000:1000)"
        if sudo -n chown -R 1000:1000 "$MAILU_DATA_PATH/mail" 2>/dev/null; then
            echo "✔️ Mail directory ownership updated"
        else
            echo "⚠️  Need sudo access to set mail directory ownership for Mailu containers"
            sudo chown -R 1000:1000 "$MAILU_DATA_PATH/mail" || {
                echo "❌ ERROR: Could not set ownership on mail directory"
                echo "   Mailu containers may not be able to access mail data"
                echo "   Consider running: sudo chown -R 1000:1000 $MAILU_DATA_PATH/mail"
            }
        fi
    else
        echo "✔️ Mail directory ownership is already correct (1000:1000)"
    fi
else
    echo "ℹ️  Mail directory will be created with default ownership"
fi

# --- Setup Unbound Configuration ---
echo "=== Setting up Unbound DNS resolver ==="

# Create the unbound directory but let Mailu generate its own config
echo "Creating unbound directory (Mailu will generate config)..."

# Download root.hints as a fallback (optional)
echo "Downloading latest root.hints file..."
rm -f "$ROOT_HINTS_DEST_PATH"
if ! curl -s -f -o "$ROOT_HINTS_DEST_PATH" https://www.internic.net/domain/named.root; then
    echo "⚠️  WARNING: Failed to download root.hints file, continuing without it"
fi

echo "✔️ Unbound directory ready"

# --- Container Management Functions ---
remove_container() {
    local container_name="$1"
    if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        echo "  Removing container: $container_name"
        docker rm -f "$container_name" 2>/dev/null || true
    fi
}

# --- Clean up existing deployment ---
echo "=== Cleaning up existing containers ==="
remove_container "$REDIS_CONTAINER"
remove_container "$FRONT_CONTAINER"
remove_container "$ADMIN_CONTAINER"
remove_container "$IMAP_CONTAINER"
remove_container "$SMTP_CONTAINER"
remove_container "$WEBMAIL_CONTAINER"
remove_container "$RESOLVER_CONTAINER"
remove_container "mailu-forward-auth"

# --- Network Management ---
echo "=== Setting up Docker networks ==="

# Check if Traefik network exists
if ! docker network ls --format '{{.Name}}' | grep -q "^${TRAEFIK_NETWORK}$"; then
    echo "❌ ERROR: Traefik network '$TRAEFIK_NETWORK' does not exist"
    echo "   Please create it first or start Traefik"
    exit 1
fi

# Check if forward auth secrets exist
echo "=== Checking forward auth configuration ==="
FORWARD_AUTH_ENV="../secrets/forward-auth.env"
if [[ ! -f "$FORWARD_AUTH_ENV" ]]; then
    echo "⚠️  WARNING: Forward auth configuration not found at $FORWARD_AUTH_ENV"
    echo "   Please run the Keycloak client setup first:"
    echo "   cd ../keycloak && ./setup-client.sh"
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
    if ! docker pull "$image"; then
        echo "❌ ERROR: Failed to pull image $image"
        exit 1
    fi
done

echo "✔️ All images pulled successfully"

# --- Deploy Core Services ---
echo "=== Deploying core services ==="

# DNS Resolver (Unbound) with Static IP
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

# Wait for core services to be ready
echo "=== Waiting for core services to be ready ==="

echo "Initializing DNSSEC trust anchor..."
sleep 5
# Let the container initialize its own config first, then try trust anchor
sleep 5
if ! docker exec "$RESOLVER_CONTAINER" unbound-anchor -a /etc/unbound/trusted-key.key 2>/dev/null; then
    echo "⚠️  WARNING: DNSSEC trust anchor initialization failed"
    echo "   This is normal on first run - Unbound will use root hints"
fi

echo "Waiting for Unbound DNS resolver..."
timeout=60
counter=0
until docker exec "$RESOLVER_CONTAINER" dig @127.0.0.1 google.com +short 2>/dev/null | grep -q '[0-9]'; do
    if [[ $counter -ge $timeout ]]; then
        echo "❌ ERROR: Unbound failed to start within $timeout seconds"
        echo "Container logs:"
        docker logs "$RESOLVER_CONTAINER" --tail 20
        exit 1
    fi
    echo "  - Waiting for Unbound... ($counter/$timeout)"
    sleep 2
    ((counter++))
done
echo "✔️ Unbound is ready"

echo "Waiting for Redis..."
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

# --- Deploy Forward Auth Service ---
echo "=== Deploying forward authentication service ==="

# Load forward auth environment if it exists
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
    echo "⚠️  Skipping forward auth deployment - configuration not found"
    echo "   Authentication will use local Mailu accounts only"
fi

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

# Front Container (Last - connects to both networks with auth middleware)
echo "  Starting Front/Nginx container with proxy authentication..."
docker run -d \
  --name "$FRONT_CONTAINER" \
  --restart=always \
  --network="$MAILU_NETWORK" \
  --dns="$RESOLVER_ADDRESS" \
  --env-file="$ENV_FILE" \
  --hostname="$FRONT_ADDRESS" \
  -v "$MAILU_DATA_PATH/overrides/nginx:/overrides:ro" \
  -v "/home/websurfinmurf/projects/traefik/certs/ai-servicers.com:/certs:ro" \
  -l "traefik.enable=true" \
  -l "traefik.docker.network=$TRAEFIK_NETWORK" \
  \
  -l "traefik.http.routers.mailu-http.rule=Host(\`${HOSTNAMES}\`)" \
  -l "traefik.http.routers.mailu-http.entrypoints=web" \
  -l "traefik.http.routers.mailu-http.middlewares=https-redirect@file" \
  \
  -l "traefik.http.routers.mailu-https.rule=Host(\`${HOSTNAMES}\`)" \
  -l "traefik.http.routers.mailu-https.entrypoints=websecure" \
  -l "traefik.http.routers.mailu-https.service=mailu-service" \
  -l "traefik.http.routers.mailu-https.tls=true" \
  -l "traefik.http.routers.mailu-https.tls.certresolver=letsencrypt" \
  -l "traefik.http.routers.mailu-https.tls.domains[0].main=ai-servicers.com" \
  -l "traefik.http.routers.mailu-https.tls.domains[0].sans=*.ai-servicers.com" \
  -l "traefik.http.services.mailu-service.loadbalancer.server.port=80" \
  \
  -l "traefik.http.routers.mailu-admin-auth.rule=Host(\`${HOSTNAMES}\`) && PathPrefix(\`/admin\`)" \
  -l "traefik.http.routers.mailu-admin-auth.entrypoints=websecure" \
  -l "traefik.http.routers.mailu-admin-auth.middlewares=mailu-auth@docker" \
  -l "traefik.http.routers.mailu-admin-auth.service=mailu-service" \
  -l "traefik.http.routers.mailu-admin-auth.tls=true" \
  -l "traefik.http.routers.mailu-admin-auth.tls.certresolver=letsencrypt" \
  -l "traefik.http.routers.mailu-admin-auth.priority=100" \
  \
  -l "traefik.http.routers.mailu-webmail-auth.rule=Host(\`${HOSTNAMES}\`) && PathPrefix(\`/webmail\`)" \
  -l "traefik.http.routers.mailu-webmail-auth.entrypoints=websecure" \
  -l "traefik.http.routers.mailu-webmail-auth.middlewares=mailu-auth@docker" \
  -l "traefik.http.routers.mailu-webmail-auth.service=mailu-service" \
  -l "traefik.http.routers.mailu-webmail-auth.tls=true" \
  -l "traefik.http.routers.mailu-webmail-auth.tls.certresolver=letsencrypt" \
  -l "traefik.http.routers.mailu-webmail-auth.priority=100" \
  \
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

# Connect front container to Traefik network
echo "  Connecting Front container to Traefik network..."
docker network connect "$TRAEFIK_NETWORK" "$FRONT_CONTAINER"

# --- Final Health Checks ---
echo "=== Final health checks ==="

sleep 10  # Give containers time to initialize

failed_containers=()
for container in "$REDIS_CONTAINER" "$RESOLVER_CONTAINER" "$ADMIN_CONTAINER" "$IMAP_CONTAINER" "$SMTP_CONTAINER" "$WEBMAIL_CONTAINER" "$FRONT_CONTAINER"; do
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
echo "🎉 SUCCESS! Mailu deployment with proxy authentication completed!"
echo ""
echo "📍 Access points:"
if [[ -f "$FORWARD_AUTH_ENV" ]]; then
    echo "   • Admin interface: https://${HOSTNAMES%%,*}/admin (requires Keycloak login)"
    echo "   • Webmail: https://${HOSTNAMES%%,*}/webmail (requires Keycloak login)"
    echo "   • Auth service: https://auth.ai-servicers.com/_oauth"
else
    echo "   • Admin interface: https://${HOSTNAMES%%,*}/admin (local authentication)"
    echo "   • Webmail: https://${HOSTNAMES%%,*}/webmail (local authentication)"
fi
echo "   • Public webmail: https://${HOSTNAMES%%,*}/ (no auth required)"
echo ""
if [[ -f "$FORWARD_AUTH_ENV" ]]; then
    echo "🔐 Authentication:"
    echo "   • Admin/Webmail access requires Keycloak authentication"
    echo "   • Users will be redirected to: https://keycloak.ai-servicers.com"
    echo "   • After login, users are created automatically in Mailu"
    echo ""
fi
echo "📊 Container status:"
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' --filter "name=mailu-"
echo ""
echo "🔧 Next steps:"
if [[ ! -f "$FORWARD_AUTH_ENV" ]]; then
    echo "   1. Set up Keycloak OIDC client:"
    echo "      cd ../keycloak && ./setup-client.sh"
    echo "   2. Redeploy Mailu to enable proxy authentication:"
    echo "      ./deploy.sh"
    echo ""
else
    echo "   1. Test authentication flow:"
    echo "      curl -I https://${HOSTNAMES%%,*}/admin"
    echo "   2. Monitor forward auth logs:"
    echo "      docker logs mailu-forward-auth -f"
    echo ""
fi
echo "🔧 Useful commands:"
echo "   • View logs: docker logs <container-name>"
echo "   • Check status: docker ps --filter name=mailu-"
echo "   • Stop all: docker stop \$(docker ps -q --filter name=mailu-)"
echo "   • Remove all: docker rm \$(docker ps -aq --filter name=mailu-)"
