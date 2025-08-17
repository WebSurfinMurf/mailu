#!/usr/bin/env bash

# ======================================================================
# Simple Keycloak Forward Auth Fix
# ======================================================================

echo "=== Simple Keycloak Forward Auth Fix ==="

# Stop any existing forward auth
docker rm -f mailu-forward-auth 2>/dev/null || true

# Get Keycloak IP with correct syntax
KEYCLOAK_IP=$(docker inspect keycloak --format '{{.NetworkSettings.Networks.traefik-proxy.IPAddress}}')
echo "Keycloak IP: $KEYCLOAK_IP"

# Verify we can reach it
echo "Testing Keycloak connectivity..."
if docker run --rm --network traefik-proxy curlimages/curl:latest \
    curl -s -I http://$KEYCLOAK_IP:8080/realms/master/.well-known/openid-configuration | head -1; then
    echo "✔️ Keycloak reachable at $KEYCLOAK_IP:8080"
else
    echo "❌ Cannot reach Keycloak, trying container name..."
    if docker run --rm --network traefik-proxy curlimages/curl:latest \
        curl -s -I http://keycloak:8080/realms/master/.well-known/openid-configuration | head -1; then
        echo "✔️ Keycloak reachable by name"
        KEYCLOAK_IP="keycloak"
    else
        echo "❌ Cannot reach Keycloak"
        exit 1
    fi
fi

# Load environment
source ../secrets/forward-auth.env

echo ""
echo "=== Deploying Forward Auth ==="
echo "Using issuer: http://$KEYCLOAK_IP:8080/realms/master"

docker run -d \
  --name "mailu-forward-auth" \
  --restart=always \
  --network="traefik-proxy" \
  --hostname="auth" \
  -e PROVIDERS_OIDC_ISSUER_URL="http://$KEYCLOAK_IP:8080/realms/master" \
  -e PROVIDERS_OIDC_CLIENT_ID="${PROVIDERS_OIDC_CLIENT_ID}" \
  -e PROVIDERS_OIDC_CLIENT_SECRET="${PROVIDERS_OIDC_CLIENT_SECRET}" \
  -e DEFAULT_PROVIDER="oidc" \
  -e SECRET="${SECRET}" \
  -e AUTH_HOST="${AUTH_HOST}" \
  -e COOKIE_DOMAIN="${COOKIE_DOMAIN}" \
  -e LOG_LEVEL="debug" \
  -l "traefik.enable=true" \
  -l "traefik.docker.network=traefik-proxy" \
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
echo "=== Monitoring for 30 seconds ==="

for i in {1..15}; do
    echo "Check $i:"
    
    if ! docker ps -q -f name=mailu-forward-auth | grep -q .; then
        echo "❌ Container stopped"
        docker logs mailu-forward-auth
        exit 1
    fi
    
    logs=$(docker logs mailu-forward-auth 2>&1)
    echo "$(echo "$logs" | tail -1)"
    
    if echo "$logs" | grep -i "listening.*4181" > /dev/null; then
        echo ""
        echo "🎉 SUCCESS! Forward auth is listening!"
        
        echo "Testing endpoints..."
        sleep 3
        
        # Test internal
        if docker exec mailu-forward-auth wget -q --spider http://localhost:4181; then
            echo "✔️ Internal endpoint OK"
        fi
        
        # Test external
        if curl -s -I https://${AUTH_HOST}/_oauth | head -1; then
            echo "✔️ External endpoint OK"
            echo ""
            echo "🚀 READY! Test: https://mail.ai-servicers.com/sso/admin/"
        else
            echo "⚠️ External endpoint not ready yet"
        fi
        break
    fi
    
    sleep 2
done

echo ""
echo "Final logs:"
docker logs mailu-forward-auth
