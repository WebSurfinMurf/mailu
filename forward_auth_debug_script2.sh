#!/usr/bin/env bash

# ======================================================================
# Forward Auth Debug Script - Troubleshoot startup issues
# ======================================================================

set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
cd "$SCRIPT_DIR"

FORWARD_AUTH_ENV="../secrets/forward-auth.env"
TRAEFIK_NETWORK="traefik-proxy"

echo "=== Forward Auth Debugging Script ==="
echo "Timestamp: $(date)"
echo ""

# --- Check Environment File ---
echo "1. Checking forward-auth.env file..."
if [[ ! -f "$FORWARD_AUTH_ENV" ]]; then
    echo "❌ ERROR: $FORWARD_AUTH_ENV not found!"
    exit 1
fi

echo "✔️ Environment file exists"
echo "File size: $(stat -c%s "$FORWARD_AUTH_ENV") bytes"
echo "File permissions: $(stat -c%a "$FORWARD_AUTH_ENV")"
echo ""

# Load and validate environment
source "$FORWARD_AUTH_ENV"

echo "2. Validating critical environment variables..."
required_vars=(
    "PROVIDERS_OIDC_ISSUER_URL"
    "PROVIDERS_OIDC_CLIENT_ID" 
    "PROVIDERS_OIDC_CLIENT_SECRET"
    "SECRET"
    "AUTH_HOST"
    "COOKIE_DOMAIN"
)

missing_vars=()
for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        missing_vars+=("$var")
    else
        echo "✔️ $var: ${!var:0:20}..." # Show first 20 chars only
    fi
done

if [[ ${#missing_vars[@]} -gt 0 ]]; then
    echo "❌ ERROR: Missing required variables:"
    printf '   - %s\n' "${missing_vars[@]}"
    exit 1
fi
echo ""

# --- Check Network ---
echo "3. Checking Docker network..."
if ! docker network ls --format '{{.Name}}' | grep -q "^${TRAEFIK_NETWORK}$"; then
    echo "❌ ERROR: Traefik network '$TRAEFIK_NETWORK' does not exist"
    echo "Available networks:"
    docker network ls
    exit 1
fi
echo "✔️ Traefik network exists"
echo ""

# --- Stop existing container ---
echo "4. Cleaning up existing forward auth container..."
if docker ps -a --format '{{.Names}}' | grep -q "^mailu-forward-auth$"; then
    echo "Stopping and removing existing container..."
    docker rm -f mailu-forward-auth
fi
echo "✔️ Cleanup complete"
echo ""

# --- Test image pull ---
echo "5. Testing image availability..."
if ! docker pull thomseddon/traefik-forward-auth:2; then
    echo "❌ ERROR: Failed to pull forward auth image"
    exit 1
fi
echo "✔️ Image pulled successfully"
echo ""

# --- Start container with debug logging ---
echo "6. Starting forward auth container with debug logging..."

# Create the container with explicit debug configuration
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
  -e HEADERS_USERNAME="${HEADERS_USERNAME:-X-Auth-Email}" \
  -e HEADERS_GROUPS="${HEADERS_GROUPS:-X-Auth-Groups}" \
  -e HEADERS_NAME="${HEADERS_NAME:-X-Auth-Name}" \
  -e URL_PATH="${URL_PATH:-/_oauth}" \
  -e LOGOUT_REDIRECT="${LOGOUT_REDIRECT:-}" \
  -e LIFETIME="${LIFETIME:-86400}" \
  -e LOG_LEVEL="${LOG_LEVEL:-debug}" \
  -e INSECURE_COOKIE="${INSECURE_COOKIE:-false}" \
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

echo "✔️ Container started"
echo ""

# --- Monitor startup ---
echo "7. Monitoring container startup..."
echo "Waiting for container to initialize..."

# Wait and show logs
sleep 5

echo "=== Container Status ==="
docker ps --filter name=mailu-forward-auth --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
echo ""

echo "=== Initial Logs ==="
docker logs mailu-forward-auth
echo ""

# Check for specific startup indicators
timeout=60
counter=0
startup_success=false

echo "Checking for successful startup indicators..."
while [[ $counter -lt $timeout ]]; do
    logs=$(docker logs mailu-forward-auth 2>&1)
    
    # Check for various success indicators
    if echo "$logs" | grep -i -E "(listening|server started|ready|serving)" > /dev/null; then
        startup_success=true
        echo "✔️ Forward auth appears to be running!"
        break
    fi
    
    # Check for obvious errors
    if echo "$logs" | grep -i -E "(error|failed|panic|fatal)" > /dev/null; then
        echo "❌ ERROR detected in logs:"
        echo "$logs" | grep -i -E "(error|failed|panic|fatal)" | tail -5
        break
    fi
    
    # Check if container is still running
    if ! docker ps --format '{{.Names}}' | grep -q "^mailu-forward-auth$"; then
        echo "❌ ERROR: Container stopped running"
        echo "Exit code: $(docker inspect mailu-forward-auth --format='{{.State.ExitCode}}')"
        break
    fi
    
    echo "  - Still starting... ($counter/$timeout)"
    sleep 2
    ((counter++))
done

echo ""
echo "=== Final Status ==="
if docker ps --format '{{.Names}}' | grep -q "^mailu-forward-auth$"; then
    echo "✔️ Container is running"
    
    # Test internal connectivity
    echo "Testing internal connectivity..."
    if docker exec mailu-forward-auth wget -q --spider http://localhost:4181 2>/dev/null; then
        echo "✔️ Internal HTTP endpoint responding"
    else
        echo "⚠️ Internal HTTP endpoint not responding"
    fi
    
    # Show current environment variables (sanitized)
    echo ""
    echo "=== Container Environment (sanitized) ==="
    docker exec mailu-forward-auth env | grep -E '^(PROVIDERS_|DEFAULT_|AUTH_|COOKIE_|HEADERS_|URL_|LOG_)' | sed 's/SECRET.*/SECRET=***/' | sed 's/CLIENT_SECRET.*/CLIENT_SECRET=***/'
    
else
    echo "❌ Container is not running"
fi

echo ""
echo "=== Complete Logs ==="
docker logs mailu-forward-auth
echo ""

echo "=== Network Information ==="
docker network inspect "$TRAEFIK_NETWORK" | jq -r '.[] | .Containers | to_entries[] | select(.value.Name == "mailu-forward-auth") | "IP: " + .value.IPv4Address'

echo ""
echo "=== Troubleshooting Commands ==="
echo "Monitor logs: docker logs -f mailu-forward-auth"
echo "Check health: docker exec mailu-forward-auth wget -q --spider http://localhost:4181"
echo "Test endpoint: curl -I https://${AUTH_HOST}/_oauth"
echo "Container shell: docker exec -it mailu-forward-auth sh"
echo ""

if [[ "$startup_success" == true ]]; then
    echo "🎉 Forward auth appears to be working!"
    echo ""
    echo "Next step: Test the authentication flow:"
    echo "1. Visit: https://mail.ai-servicers.com/sso/admin/"
    echo "2. Should redirect to Keycloak"
    echo "3. Login with: websurfinmurf / Qwert-0987lr"
    echo "4. Should redirect back to Mailu admin"
else
    echo "❌ Forward auth startup failed"
    echo ""
    echo "Common issues to check:"
    echo "1. CLIENT_SECRET mismatch between Keycloak and forward-auth.env"
    echo "2. Issuer URL not accessible from container"
    echo "3. Network connectivity issues"
    echo "4. Certificate/TLS issues"
    echo ""
    echo "Run this script again after fixing issues."
fi
