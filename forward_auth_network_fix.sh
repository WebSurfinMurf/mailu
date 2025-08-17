#!/usr/bin/env bash

# ======================================================================
# Forward Auth Network Fix - Resolve DNS connectivity issue
# ======================================================================

set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
cd "$SCRIPT_DIR"

FORWARD_AUTH_ENV="../secrets/forward-auth.env"
TRAEFIK_NETWORK="traefik-proxy"

echo "=== Forward Auth Network Fix ==="

# Load environment
source "$FORWARD_AUTH_ENV"

# Stop the failing container
echo "Stopping problematic forward auth container..."
docker rm -f mailu-forward-auth 2>/dev/null || true

echo ""
echo "=== Testing Network Connectivity ==="

# Test 1: Check if host can reach Keycloak
echo "1. Testing from host:"
if curl -I --connect-timeout 5 https://keycloak.ai-servicers.com/realms/master/.well-known/openid-configuration 2>/dev/null | head -1; then
    echo "✔️ Host can reach Keycloak"
else
    echo "❌ Host cannot reach Keycloak - check your DNS/network setup"
    exit 1
fi

# Test 2: Check what DNS servers the host is using
echo ""
echo "2. Host DNS configuration:"
echo "Nameservers:"
cat /etc/resolv.conf | grep nameserver
echo ""

# Get the host's primary DNS server
HOST_DNS=$(cat /etc/resolv.conf | grep nameserver | head -1 | awk '{print $2}')
echo "Primary DNS server: $HOST_DNS"

# Test 3: Test from a container with host DNS
echo ""
echo "3. Testing from container with host DNS:"
if docker run --rm --dns="$HOST_DNS" --dns=192.168.1.1 curlimages/curl:latest \
    curl -I --connect-timeout 10 https://keycloak.ai-servicers.com/realms/master/.well-known/openid-configuration 2>/dev/null | head -1; then
    echo "✔️ Container with host DNS can reach Keycloak"
    DNS_FIX="--dns=$HOST_DNS --dns=192.168.1.1"
else
    echo "❌ Even with host DNS, container cannot reach Keycloak"
    echo "Trying with host networking..."
    
    # Test 4: Try with host networking
    if docker run --rm --network host curlimages/curl:latest \
        curl -I --connect-timeout 10 https://keycloak.ai-servicers.com/realms/master/.well-known/openid-configuration 2>/dev/null | head -1; then
        echo "✔️ Container with host networking can reach Keycloak"
        echo "⚠️ Will need to use host networking for forward auth"
        DNS_FIX="--network host"
    else
        echo "❌ Network connectivity issue - check firewall/routing"
        exit 1
    fi
fi

echo ""
echo "=== Deploying Fixed Forward Auth ==="

# Deploy with proper DNS configuration
if [[ "$DNS_FIX" == "--network host" ]]; then
    echo "Using host networking (last resort)..."
    docker run -d \
      --name "mailu-forward-auth" \
      --restart=always \
      --network host \
      -e PROVIDERS_OIDC_ISSUER_URL="${PROVIDERS_OIDC_ISSUER_URL}" \
      -e PROVIDERS_OIDC_CLIENT_ID="${PROVIDERS_OIDC_CLIENT_ID}" \
      -e PROVIDERS_OIDC_CLIENT_SECRET="${PROVIDERS_OIDC_CLIENT_SECRET}" \
      -e DEFAULT_PROVIDER="oidc" \
      -e SECRET="${SECRET}" \
      -e AUTH_HOST="${AUTH_HOST}" \
      -e COOKIE_DOMAIN="${COOKIE_DOMAIN}" \
      -e HEADERS_USERNAME="${HEADERS_USERNAME:-X-Auth-Email}" \
      -e HEADERS_GROUPS="${HEADERS_GROUPS:-X-Auth-Groups}" \
      -e HEADERS_NAME="${HEADERS_NAME:-X-Auth-Name}" \
      -e URL_PATH="${URL_PATH:-/_oauth}" \
      -e LOGOUT_REDIRECT="${LOGOUT_REDIRECT:-}" \
      -e LIFETIME="${LIFETIME:-86400}" \
      -e LOG_LEVEL="debug" \
      -e INSECURE_COOKIE="false" \
      thomseddon/traefik-forward-auth:2
    
    # Connect to Traefik network after startup
    sleep 10
    docker network connect "$TRAEFIK_NETWORK" mailu-forward-auth
    
else
    echo "Using bridge networking with custom DNS..."
    docker run -d \
      --name "mailu-forward-auth" \
      --restart=always \
      --network="$TRAEFIK_NETWORK" \
      --hostname="auth" \
      $DNS_FIX \
      --add-host="keycloak.ai-servicers.com:192.168.1.13" \
      -e PROVIDERS_OIDC_ISSUER_URL="${PROVIDERS_OIDC_ISSUER_URL}" \
      -e PROVIDERS_OIDC_CLIENT_ID="${PROVIDERS_OIDC_CLIENT_ID}" \
      -e PROVIDERS_OIDC_CLIENT_SECRET="${PROVIDERS_OIDC_CLIENT_SECRET}" \
      -e DEFAULT_PROVIDER="oidc" \
      -e SECRET="${SECRET}" \
      -e AUTH_HOST="${AUTH_HOST}" \
      -e COOKIE_DOMAIN="${COOKIE_DOMAIN}" \
      -e HEADERS_USERNAME="${HEADERS_USERNAME:-X-Auth-Email}" \
      -e HEADERS_GROUPS="${HEADERS_GROUPS:-X-Auth-Groups}" \
      -e HEADERS_NAME="${HEADERS_NAME:-X-Auth-Name}" \
      -e URL_PATH="${URL_PATH:-/_oauth}" \
      -e LOGOUT_REDIRECT="${LOGOUT_REDIRECT:-}" \
      -e LIFETIME="${LIFETIME:-86400}" \
      -e LOG_LEVEL="debug" \
      -e INSECURE_COOKIE="false" \
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
fi

echo ""
echo "=== Monitoring Startup ==="
sleep 5

# Monitor for 30 seconds
for i in {1..15}; do
    echo "--- Check $i ---"
    
    # Check if container is running
    if ! docker ps --format '{{.Names}}' | grep -q "^mailu-forward-auth$"; then
        echo "❌ Container stopped running"
        echo "Logs:"
        docker logs mailu-forward-auth
        exit 1
    fi
    
    # Check logs for success/failure
    logs=$(docker logs mailu-forward-auth 2>&1)
    
    if echo "$logs" | grep -i "listening\|ready\|started" > /dev/null; then
        echo "✔️ SUCCESS: Forward auth is running!"
        break
    elif echo "$logs" | grep -i "fatal\|error" > /dev/null; then
        echo "❌ FAILED: Found errors in logs"
        echo "$logs"
        exit 1
    else
        echo "  Still starting..."
        echo "  Latest: $(echo "$logs" | tail -1)"
    fi
    
    sleep 2
done

echo ""
echo "=== Final Status ==="
docker ps --filter name=mailu-forward-auth --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
echo ""
echo "=== Testing Auth Endpoint ==="
sleep 5

# Test the auth endpoint
if curl -I --connect-timeout 10 https://${AUTH_HOST}/_oauth 2>/dev/null | head -1; then
    echo "✔️ Auth endpoint responding"
else
    echo "⚠️ Auth endpoint not responding yet (may need more time)"
fi

echo ""
echo "=== Next Steps ==="
echo "1. Test the authentication flow:"
echo "   https://mail.ai-servicers.com/sso/admin/"
echo ""
echo "2. Should redirect to Keycloak login"
echo ""
echo "3. Login with: websurfinmurf / Qwert-0987lr"
echo ""
echo "4. Should redirect back to Mailu admin"

echo ""
echo "=== Logs ==="
docker logs mailu-forward-auth
