#!/usr/bin/env bash
set -euo pipefail

echo "Betterbase Setup"
echo "================"

# Check for docker
if ! command -v docker &> /dev/null; then
    echo "Error: docker is required but not installed."
    exit 1
fi

# Generate .env if it doesn't exist
if [ ! -f .env ]; then
    echo "Creating .env from .env.example..."
    cp .env.example .env

    # Generate random keys
    IDENTITY_HASH_KEY=$(openssl rand -hex 32)
    CAP_ADMIN_KEY=$(openssl rand -hex 32)

    # Update .env with generated values
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s/^IDENTITY_HASH_KEY=$/IDENTITY_HASH_KEY=$IDENTITY_HASH_KEY/" .env
        sed -i '' "s/^CAP_ADMIN_KEY=$/CAP_ADMIN_KEY=$CAP_ADMIN_KEY/" .env
    else
        sed -i "s/^IDENTITY_HASH_KEY=$/IDENTITY_HASH_KEY=$IDENTITY_HASH_KEY/" .env
        sed -i "s/^CAP_ADMIN_KEY=$/CAP_ADMIN_KEY=$CAP_ADMIN_KEY/" .env
    fi

    echo "Generated IDENTITY_HASH_KEY and CAP_ADMIN_KEY."
    echo ""
    echo "You still need to configure:"
    echo "  1. OPAQUE_SERVER_SETUP - Run: docker run --rm ghcr.io/betterbasehq/betterbase-accounts keygen"
    echo "  2. CAP_KEY_ID and CAP_SECRET - Will be auto-provisioned on first run"
    echo "  3. OAUTH_ISSUER - Your accounts server public URL"
    echo "  4. SYNC_ENDPOINT - Your sync server public URL"
    echo ""
else
    echo ".env already exists, skipping generation."
fi

echo ""
echo "To start Betterbase:"
echo "  docker compose up -d"
echo ""
echo "To check health:"
echo "  docker compose ps"
