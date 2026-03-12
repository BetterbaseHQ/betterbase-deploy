#!/usr/bin/env bash
set -euo pipefail

# Parse arguments
DOMAIN=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --domain)
            DOMAIN="$2"
            shift 2
            ;;
        --domain=*)
            DOMAIN="${1#*=}"
            shift
            ;;
        -h|--help)
            echo "Usage: ./setup.sh [--domain example.com]"
            echo ""
            echo "Options:"
            echo "  --domain    Production domain (sets up https://accounts.DOMAIN"
            echo "              and https://sync.DOMAIN). Defaults to localhost."
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Run './setup.sh --help' for usage."
            exit 1
            ;;
    esac
done

echo "Betterbase Setup"
echo "================"

# Check for docker
if ! command -v docker &> /dev/null; then
    echo "Error: docker is required but not installed."
    exit 1
fi

sed_inplace() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

# ==========================================================================
# Step 1: Generate .env
# ==========================================================================

if [ ! -f .env ]; then
    echo "Creating .env from .env.example..."
    cp .env.example .env
    chmod 600 .env

    # Generate random keys
    IDENTITY_HASH_KEY=$(openssl rand -hex 32)
    CAP_ADMIN_KEY=$(openssl rand -hex 32)

    sed_inplace "s/^IDENTITY_HASH_KEY=$/IDENTITY_HASH_KEY=$IDENTITY_HASH_KEY/" .env
    sed_inplace "s/^CAP_ADMIN_KEY=$/CAP_ADMIN_KEY=$CAP_ADMIN_KEY/" .env

    echo "Generated IDENTITY_HASH_KEY and CAP_ADMIN_KEY."
else
    echo ".env already exists, skipping generation."
fi

# Apply --domain if provided
if [ -n "$DOMAIN" ]; then
    if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
        echo "Error: Invalid domain format: $DOMAIN"
        exit 1
    fi
    echo "Configuring for domain: $DOMAIN"
    sed_inplace "s|^OAUTH_ISSUER=.*|OAUTH_ISSUER=https://accounts.$DOMAIN|" .env
    sed_inplace "s|^SYNC_ENDPOINT=.*|SYNC_ENDPOINT=https://sync.$DOMAIN/api/v1|" .env
fi

# Source current .env values
set -a
# shellcheck disable=SC1091
source .env
set +a

# ==========================================================================
# Step 2: Generate OPAQUE keys if not set
# ==========================================================================

if [ -z "${OPAQUE_SERVER_SETUP:-}" ]; then
    echo ""
    echo "Generating OPAQUE server keys..."
    OPAQUE_SERVER_SETUP=$(docker run --rm --entrypoint /app/keygen ghcr.io/betterbasehq/betterbase-accounts:latest 2>/dev/null)

    if [ -z "$OPAQUE_SERVER_SETUP" ]; then
        echo "Error: OPAQUE keygen produced no output. Check Docker image availability."
        exit 1
    fi

    sed_inplace "/^OPAQUE_SERVER_SETUP=$/d" .env
    printf 'OPAQUE_SERVER_SETUP=%s\n' "$OPAQUE_SERVER_SETUP" >> .env
    echo "Generated OPAQUE_SERVER_SETUP."
else
    echo "OPAQUE_SERVER_SETUP already configured."
fi

# ==========================================================================
# Step 3: Provision CAP keys if not set
# ==========================================================================

if [ -z "${CAP_KEY_ID:-}" ] || [ -z "${CAP_SECRET:-}" ]; then
    if [ -z "${CAP_ADMIN_KEY:-}" ]; then
        echo "Error: CAP_ADMIN_KEY is not set in .env. Cannot provision CAP."
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        echo "Error: jq is required for CAP provisioning but not installed."
        exit 1
    fi

    echo ""
    echo "Provisioning CAP (proof-of-work CAPTCHA)..."

    # Start CAP and wait for it to be healthy
    echo "Starting CAP service..."
    docker compose up -d --wait cap

    echo "CAP service is ready."

    # We need curl inside the network — use the accounts image since it has curl
    echo "Pulling accounts image for network access..."
    docker compose pull accounts >/dev/null 2>&1

    cap_curl() {
        docker compose run --rm --no-deps -T --entrypoint curl accounts \
            -sf --connect-timeout 5 --max-time 10 "$@"
    }

    # Login to CAP admin API
    echo "Authenticating with CAP..."
    login_response=$(cap_curl -X POST http://cap:3000/auth/login \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg k "$CAP_ADMIN_KEY" '{"admin_key":$k}')")

    session_token=$(echo "$login_response" | jq -r '.session_token')
    hashed_token=$(echo "$login_response" | jq -r '.hashed_token')

    if [ "$session_token" = "null" ] || [ -z "$session_token" ]; then
        echo "Error: Failed to authenticate with CAP."
        docker compose stop cap
        exit 1
    fi

    if [ "$hashed_token" = "null" ] || [ -z "$hashed_token" ]; then
        echo "Error: CAP login response missing hashed_token."
        docker compose stop cap
        exit 1
    fi

    # Create bearer auth token (base64 encoded JSON)
    auth_token=$(jq -n --arg t "$session_token" --arg h "$hashed_token" '{"token":$t,"hash":$h}' | base64 | tr -d '\n')

    # Create site key
    echo "Creating CAP site key..."
    key_response=$(cap_curl -X POST http://cap:3000/server/keys \
        -H "Authorization: Bearer $auth_token" \
        -H "Content-Type: application/json" \
        -d '{"name":"betterbase-accounts"}')

    CAP_KEY_ID=$(echo "$key_response" | jq -r '.siteKey')
    CAP_SECRET=$(echo "$key_response" | jq -r '.secretKey')

    if [ "$CAP_KEY_ID" = "null" ] || [ -z "$CAP_KEY_ID" ]; then
        echo "Error: Failed to create CAP site key."
        docker compose stop cap
        exit 1
    fi

    sed_inplace "/^CAP_KEY_ID=$/d" .env
    sed_inplace "/^CAP_SECRET=$/d" .env
    printf 'CAP_KEY_ID=%s\n' "$CAP_KEY_ID" >> .env
    printf 'CAP_SECRET=%s\n' "$CAP_SECRET" >> .env

    echo "CAP site key created."

    # Stop CAP (will be started with full stack)
    docker compose stop cap
else
    echo "CAP credentials already configured."
fi

# ==========================================================================
# Done
# ==========================================================================

# Re-source to pick up any changes
set -a
# shellcheck disable=SC1091
source .env
set +a

echo ""
echo "Setup complete!"
echo ""
echo "  OAUTH_ISSUER:  $OAUTH_ISSUER"
echo "  SYNC_ENDPOINT: $SYNC_ENDPOINT"
echo ""
if [[ "$OAUTH_ISSUER" == *"localhost"* ]]; then
    echo "  Using localhost defaults. For production, re-run with:"
    echo "    ./setup.sh --domain yourdomain.com"
    echo ""
fi
echo "To start Betterbase:"
echo "  docker compose up -d"
echo ""
echo "To check health:"
echo "  docker compose ps"
