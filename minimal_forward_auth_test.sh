#!/usr/bin/env bash

# ======================================================================
# Minimal Forward Auth Test - Strip down to basics
# ======================================================================

set -euo pipefail

echo "=== Minimal Forward Auth Test ==="

# Stop any existing container
docker rm -f mailu-forward-auth 2>/dev/null || true

# Source the environment
source ../secrets/forward-auth.env

echo "Testing with minimal configuration..."

# Start with absolute minimal config for testing
docker run -d \
  --name "mailu-forward-auth-test" \
  --network="traefik-proxy" \
  -p 4181:4181 \
  -e PROVIDERS_OIDC_ISSUER_URL="${PROVIDERS_OIDC_ISSUER_URL}" \
  -e PROVIDERS_OIDC_CLIENT_ID="${PROVIDERS_OIDC_CLIENT_ID}" \
  -e PROVIDERS_OIDC_CLIENT_SECRET="${PROVIDERS_OIDC_CLIENT_SECRET}" \
  -e SECRET="${SECRET}" \
  -e LOG_LEVEL="debug" \
  -e AUTH_HOST="${AUTH_HOST}" \
  -e COOKIE_DOMAIN="${COOKIE_DOMAIN}" \
  thomseddon/traefik-forward-auth:2

echo "Container started. Monitoring logs for 30 seconds..."

# Monitor for 30 seconds
for i in {1..15}; do
    echo "--- Attempt $i ---"
    if docker logs mailu-forward-auth-test 2>&1 | tail -10; then
        if docker logs mailu-forward-auth-test 2>&1 | grep -i "listening\|ready\|started"; then
            echo "✔️ SUCCESS: Forward auth is running!"
            break
        fi
    fi
    sleep 2
done

echo ""
echo "=== Final Status ==="
docker ps --filter name=mailu-forward-auth-test
echo ""
echo "=== Test HTTP Response ==="
curl -I http://localhost:4181 2>/dev/null || echo "HTTP test failed"

echo ""
echo "=== Complete Logs ==="
docker logs mailu-forward-auth-test

echo ""
echo "Cleanup: docker rm -f mailu-forward-auth-test"
