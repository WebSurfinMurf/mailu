#!/usr/bin/env bash

# ======================================================================
# Mailu Deployment Script - Complete with Proxy Authentication
# Version: 2.0 - Fixed and Enhanced
# ======================================================================

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Determine script directory
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

if [ ! -d "$SCRIPT_DIR" ]; then
    log_error "Could not determine the script's directory."
    exit 1
fi

cd "$SCRIPT_DIR"

# Configuration paths
ENV_FILE="${ENV_FILE:-../secrets/mailu.env}"
FORWARD_AUTH_ENV="${FORWARD_AUTH_ENV:-../secrets/forward-auth.env}"

# If mailu.env doesn't exist in secrets, check current directory
if [[ ! -f "$ENV_FILE" ]]; then
    if [[ -f "$SCRIPT_DIR/mailu.env" ]]; then
        ENV_FILE="$SCRIPT_DIR/mailu.env"
        log_info "Using mailu.env from script directory"
    else
        log_error "Environment file not found at $ENV_FILE or $SCRIPT_DIR/mailu.env"
        exit 1
    fi
fi

# --- Pre-flight Checks ---
echo "=== Pre-flight Checks ==="

if [[ $EUID -eq 0 ]]; then
   log_warning "Running as root. Consider using a non-root user with docker group membership."
fi

if ! command -v docker &> /dev/null; then
    log_error "Docker is not installed or not in PATH"
    exit 1
fi

if ! docker info &> /dev/null; then
    log_error "Docker daemon is not running or user lacks permissions"
    exit 1
fi

# --- Load Environment Variables ---
log_info "Loading environment variables from $ENV_FILE..."
set -o allexport
source "$ENV_FILE"
set +o allexport

# Set default values if not defined
DOCKER_ORG="${DOCKER_ORG:-mailu}"
MAILU_VERSION="${MAILU_VERSION:-2024.06}"
SUBNET="${SUBNET:-172.30.0.0/24}"
RESOLVER_ADDRESS="${RESOLVER_ADDRESS:-172.30.0.254}"
MAILU_NETWORK="${MAILU_NETWORK:-mailu}"
TRAEFIK_NETWORK="${TRAEFIK_NETWORK:-traefik-proxy}"

# Container names with defaults
REDIS_CONTAINER="${REDIS_CONTAINER:-mailu-redis}"
REDIS_HOST="${REDIS_HOST:-redis}"
FRONT_CONTAINER="${FRONT_CONTAINER:-mailu-front}"
FRONT_ADDRESS="${FRONT_ADDRESS:-front}"
ADMIN_CONTAINER="${ADMIN_CONTAINER:-mailu-admin}"
IMAP_CONTAINER="${IMAP_CONTAINER:-mailu-imap}"
SMTP_CONTAINER="${SMTP_CONTAINER:-mailu-smtp}"
WEBMAIL_CONTAINER="${WEBMAIL_CONTAINER:-mailu-webmail}"
RESOLVER_CONTAINER="${RESOLVER_CONTAINER:-mailu-resolver}"

# --- Validate Critical Environment Variables ---
echo "=== Validating Environment Variables ==="

# Check SECRET_KEY
if [[ -z "${SECRET_KEY:-}" ]]; then
    log_error "SECRET_KEY is not set"
    echo "   Generate a new one with: openssl rand -hex 16"
    exit 1
elif [[ ${#SECRET_KEY} -ne 32 ]]; then
    log_error "SECRET_KEY must be exactly 32 characters long (current: ${#SECRET_KEY})"
    echo "   Generate a new one with: openssl rand -hex 16"
    exit 1
fi

# Check required variables
required_vars=("DOMAIN" "HOSTNAMES" "POSTMASTER")
for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        log_error "Required variable $var is not set"
        exit 1
    fi
done

log_success "Environment validation passed"

# --- Setup Data Directories ---
MAILU_DATA_PATH="${MAILU_DATA_PATH:-$SCRIPT_DIR/../data/mailu}"
UNBOUND_DATA_PATH="$MAILU_DATA_PATH/unbound"

echo "=== Setting up data directories ==="
log_info "Data path: $MAILU_DATA_PATH"

# Create all required directories
mkdir -p "$MAILU_DATA_PATH"/{data,dkim,mail,mailqueue,overrides/postfix,overrides/dovecot,overrides/nginx,webmail}
mkdir -p "$UNBOUND_DATA_PATH"

# Fix mail directory ownership if needed
if [[ -d "$MAILU_DATA_PATH/mail" ]]; then
    current_owner=$(stat -c '%u:%g' "$MAILU_DATA_PATH/mail" 2>/dev/null || echo "unknown")
    if [[ "$current_owner" != "1000:1000" ]]; then
        log_info "Fixing mail directory ownership..."
        if command -v sudo &> /dev/null; then
            sudo chown -R 1000:1000 "$MAILU_DATA_PATH/mail" || {
                log_warning "Could not set ownership on mail directory"
                echo "   Run manually: sudo chown -R 1000:1000 $MAILU_DATA_PATH/mail"
            }
        else
            log_warning "sudo not available, skipping ownership fix"
            echo "   Run manually: chown -R 1000:1000 $MAILU_DATA_PATH/mail"
        fi
    fi
fi

# Download root.hints for Unbound
log_info "Downloading latest root.hints file..."
if command -v curl &> /dev/null; then
    curl -s -f -o "$UNBOUND_DATA_PATH/root.hints" https://www.internic.net/domain/named.root || {
        log_warning "Failed to download root.hints file"
    }
elif command -v wget &> /dev/null; then
    wget -q -O "$UNBOUND_DATA_PATH/root.hints" https://www.internic.net/domain/named.root || {
        log_warning "Failed to download root.hints file"
    }
else
    log_warning "Neither curl nor wget available, skipping root.hints download"
fi

# --- Container Management Functions ---
remove_container() {
    local container_name="$1"
    if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        log_info "Removing container: $container_name"
        docker rm -f "$container_name" 2>/dev/null || true
    fi
}

wait_for_container() {
    local container_name="$1"
    local check_command="$2"
    local timeout="${3:-60}"
    local counter=0
    
    while ! eval "$check_command" 2>/dev/null; do
        if [[ $counter -ge $timeout ]]; then
            log_error "$container_name failed to start within $timeout seconds"
            docker logs "$container_name" --tail 20
            return 1
        fi
        echo -n "."
        sleep 2
        ((counter++))
    done
    echo ""
    return 0
}

# --- Clean up existing containers ---
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

# Check for Traefik network
if ! docker network ls --format '{{.Name}}' | grep -q "^${TRAEFIK_NETWORK}$"; then
    log_warning "Traefik network '$TRAEFIK_NETWORK' does not exist"
    echo "   Creating it now..."
    docker network create "$TRAEFIK_NETWORK" || {
        log_error "Failed to create Traefik network"
        exit 1
    }
fi

# Recreate Mailu network
log_info "Recreating Docker network '$MAILU_NETWORK' with subnet $SUBNET..."
docker network rm "$MAILU_NETWORK" 2>/dev/null || true
docker network create --subnet="$SUBNET" "$MAILU_NETWORK" || {
    log_error "Failed to create Mailu network"
    exit 1
}

# --- Pull Images ---
echo "=== Pulling Docker images ==="
images=(
    "redis:alpine"
    "$DOCKER_ORG/unbound:$MAILU_VERSION"
    "$DOCKER_ORG/nginx:$MAILU_VERSION"
    "$DOCKER_ORG/admin:$MAILU_VERSION"
    "$DOCKER_ORG/dovecot:$MAILU_VERSION"
    "$DOCKER_ORG/postfix:$MAILU_VERSION"
    "$DOCKER_ORG/webmail:$MAILU_VERSION"
)

# Add forward auth image if config exists
if [[ -f "$FORWARD_AUTH_ENV" ]]; then
    images+=("thomseddon/traefik-forward-auth:2")
fi

for image in "${images[@]}"; do
    log_info "Pulling $image..."
    docker pull "$image" || {
        log_error "Failed to pull image $image"
        exit 1
    }
done

log_success "All images pulled successfully"

# --- Deploy Forward Auth Service (if configured) ---
if [[ -f "$FORWARD_AUTH_ENV" ]]; then
    echo "=== Deploying forward authentication service ==="
    
    log_info "Loading forward auth configuration..."
    set -o allexport
    source "$FORWARD_AUTH_ENV"
    set +o allexport
    
    log_info "Starting Forward Auth container..."
    docker run -d \
      --name "mailu-forward-auth" \
      --restart=always \
      --network="$TRAEFIK_NETWORK" \
      --hostname="auth" \
      -e PROVIDERS_OIDC_ISSUER_URL="${PROVIDERS_OIDC_ISSUER_URL:-}" \
      -e PROVIDERS_OIDC_CLIENT_ID="${PROVIDERS_OIDC_CLIENT_ID:-}" \
      -e PROVIDERS_OIDC_CLIENT_SECRET="${PROVIDERS_OIDC_CLIENT_SECRET:-}" \
      -e DEFAULT_PROVIDER="${DEFAULT_PROVIDER:-oidc}" \
      -e PROVIDERS_GOOGLE_CLIENT_ID="${PROVIDERS_GOOGLE_CLIENT_ID:-}" \
      -e PROVIDERS_GOOGLE_CLIENT_SECRET="${PROVIDERS_GOOGLE_CLIENT_SECRET:-}" \
      -e SECRET="${SECRET:-}" \
      -e AUTH_HOST="${AUTH_HOST:-}" \
      -e COOKIE_DOMAIN="${COOKIE_DOMAIN:-}" \
      -e HEADERS_USERNAME="${HEADERS_USERNAME:-X-Auth-User}" \
      -e HEADERS_GROUPS="${HEADERS_GROUPS:-X-Auth-Groups}" \
      -e HEADERS_NAME="${HEADERS_NAME:-X-Auth-Name}" \
      -e URL_PATH="${URL_PATH:-/_oauth}" \
      -e LOGOUT_REDIRECT="${LOGOUT_REDIRECT:-}" \
      -e LIFETIME="${LIFETIME:-43200}" \
      -e LOG_LEVEL="${LOG_LEVEL:-info}" \
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
    
    log_info "Waiting for forward auth service..."
    sleep 5
    if docker ps --format '{{.Names}}' | grep -q "^mailu-forward-auth$"; then
        log_success "Forward auth service started"
    else
        log_warning "Forward auth may not be ready, check logs with: docker logs mailu-forward-auth"
    fi
else
    log_info "Skipping forward auth deployment - configuration not found"
fi

# --- Deploy Core Services ---
echo "=== Deploying core services ==="

# DNS Resolver (Unbound)
log_info "Starting DNS resolver container..."
docker run -d \
  --name "$RESOLVER_CONTAINER" \
  --restart=always \
  --network="$MAILU_NETWORK" \
  --ip="$RESOLVER_ADDRESS" \
  --env-file="$ENV_FILE" \
  -v "$UNBOUND_DATA_PATH:/data" \
  "$DOCKER_ORG/unbound:$MAILU_VERSION"

# Redis Container
log_info "Starting Redis container..."
docker run -d \
  --name "$REDIS_CONTAINER" \
  --restart=always \
  --network="$MAILU_NETWORK" \
  --hostname="$REDIS_HOST" \
  redis:alpine

# Wait for core services
log_info "Waiting for core services to be ready..."
echo -n "  Checking Unbound"
wait_for_container "$RESOLVER_CONTAINER" "docker exec $RESOLVER_CONTAINER dig @127.0.0.1 google.com +short | grep -q '[0-9]'" || exit 1
log_success "Unbound is ready"

echo -n "  Checking Redis"
wait_for_container "$REDIS_CONTAINER" "docker exec $REDIS_CONTAINER redis-cli ping | grep -q PONG" || exit 1
log_success "Redis is ready"

# --- Deploy Application Services ---
echo "=== Deploying application services ==="

# Admin Container
log_info "Starting Admin container..."
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
log_info "Starting IMAP container..."
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
log_info "Starting SMTP container..."
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
log_info "Starting Webmail container..."
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
log_info "Starting Front/Nginx container..."
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
  -l "traefik.http.services.mailu-service.loadbalancer.server.port=80" \
  "$DOCKER_ORG/nginx:$MAILU_VERSION"

# Add SSO route if forward auth is configured
if [[ -f "$FORWARD_AUTH_ENV" ]]; then
    docker rm -f "$FRONT_CONTAINER" 2>/dev/null
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
      -l "traefik.http.routers.mailu-sso.rule=Host(\`${HOSTNAMES}\`) && (PathPrefix(\`/admin\`) || PathPrefix(\`/webmail\`))" \
      -l "traefik.http.routers.mailu-sso.entrypoints=websecure" \
      -l "traefik.http.routers.mailu-sso.middlewares=mailu-auth@docker" \
      -l "traefik.http.routers.mailu-sso.service=mailu-service" \
      -l "traefik.http.routers.mailu-sso.tls=true" \
      -l "traefik.http.routers.mailu-sso.priority=100" \
      -l "traefik.http.services.mailu-service.loadbalancer.server.port=80" \
      "$DOCKER_ORG/nginx:$MAILU_VERSION"
fi

# Connect front container to Traefik network
log_info "Connecting Front container to Traefik network..."
docker network connect "$TRAEFIK_NETWORK" "$FRONT_CONTAINER" 2>/dev/null || true

# Wait for front container to initialize
log_info "Waiting for Front container to initialize..."
sleep 10

# --- Final Health Checks ---
echo "=== Running health checks ==="

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
    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        log_success "$container is running"
    else
        failed_containers+=("$container")
        log_error "$container is not running"
    fi
done

# Check forward auth separately (optional)
if [[ -f "$FORWARD_AUTH_ENV" ]]; then
    if docker ps --format '{{.Names}}' | grep -q "^mailu-forward-auth$"; then
        log_success "mailu-forward-auth is running"
    else
        log_warning "Forward auth container not running - authentication may not work"
    fi
fi

# --- Display Results ---
echo ""
if [[ ${#failed_containers[@]} -gt 0 ]]; then
    log_error "The following containers failed to start:"
    printf '   - %s\n' "${failed_containers[@]}"
    echo ""
    echo "Check container logs with:"
    printf '   docker logs %s\n' "${failed_containers[@]}"
    exit 1
fi

echo "════════════════════════════════════════════════════════════════════"
log_success "Mailu deployment completed successfully! 🎉"
echo "════════════════════════════════════════════════════════════════════"
echo ""
echo "📍 Access points:"
if [[ -f "$FORWARD_AUTH_ENV" ]]; then
    echo "   • Admin interface: https://${HOSTNAMES%%,*}/admin/ (SSO authentication)"
    echo "   • Webmail: https://${HOSTNAMES%%,*}/webmail/ (SSO authentication)"  
    echo "   • Auth endpoint: https://${AUTH_HOST:-auth.${DOMAIN}}/_oauth"
else
    echo "   • Admin interface: https://${HOSTNAMES%%,*}/admin/"
    echo "   • Webmail: https://${HOSTNAMES%%,*}/webmail/"
fi
echo "   • SMTP: ${HOSTNAMES%%,*}:25/465/587"
echo "   • IMAP: ${HOSTNAMES%%,*}:143/993"
echo ""

if [[ -f "$FORWARD_AUTH_ENV" ]]; then
    echo "🔐 Authentication:"
    echo "   • SSO Provider: ${DEFAULT_PROVIDER:-oidc}"
    echo "   • Cookie lifetime: ${LIFETIME:-43200} seconds"
    echo ""
fi

echo "📊 Container status:"
docker ps --format 'table {{.Names}}\t{{.Status}}' --filter name=mailu- | head -n 20
if [[ -f "$FORWARD_AUTH_ENV" ]]; then
    docker ps --format 'table {{.Names}}\t{{.Status}}' --filter name=mailu-forward-auth
fi

echo ""
echo "🔧 Useful commands:"
echo "   • View all logs:     docker-compose logs -f"
echo "   • View container:    docker logs <container-name>"
echo "   • Check DNS:         docker exec $RESOLVER_CONTAINER dig @127.0.0.1 ${DOMAIN}"
echo "   • Test Redis:        docker exec $REDIS_CONTAINER redis-cli ping"
echo "   • Admin shell:       docker exec -it $ADMIN_CONTAINER /bin/bash"
echo "   • Stop all:          docker stop \$(docker ps -q --filter name=mailu-)"
echo "   • Remove all:        docker rm -f \$(docker ps -aq --filter name=mailu-)"
echo ""

if [[ ! -f "$FORWARD_AUTH_ENV" ]]; then
    echo "💡 Next steps:"
    echo "   1. Configure admin user: docker exec -it $ADMIN_CONTAINER flask mailu admin admin ${DOMAIN} password"
    echo "   2. Set up SSO (optional): cd ../keycloak && ./setup-client.sh"
    echo "   3. Check DKIM keys: docker exec -it $ADMIN_CONTAINER cat /dkim/${DOMAIN}.*.txt"
fi

echo ""
log_success "Deployment complete! Check https://${HOSTNAMES%%,*}/"
