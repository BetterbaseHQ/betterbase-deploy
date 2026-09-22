#!/usr/bin/env bash
set -euo pipefail

# Parse arguments
DOMAIN=""
ACME_EMAIL=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --domain)
            [[ $# -ge 2 ]] || { echo "Error: --domain requires a value"; exit 1; }
            DOMAIN="$2"
            shift 2
            ;;
        --domain=*)
            DOMAIN="${1#*=}"
            shift
            ;;
        --email)
            [[ $# -ge 2 ]] || { echo "Error: --email requires a value"; exit 1; }
            ACME_EMAIL="$2"
            shift 2
            ;;
        --email=*)
            ACME_EMAIL="${1#*=}"
            shift
            ;;
        -h|--help)
            echo "Usage: ./setup.sh [--domain example.com] [--email you@example.com]"
            echo ""
            echo "Options:"
            echo "  --domain    Production domain. Serves https://accounts.DOMAIN,"
            echo "              https://sync.DOMAIN, and https://examples.DOMAIN with"
            echo "              automatic Let's Encrypt TLS."
            echo "              Requires DNS A records for all three subdomains"
            echo "              pointing at this server, and ports 80+443 reachable."
            echo "              Defaults to localhost (plain HTTP on ports"
            echo "              5377/5379/5380)."
            echo "  --email     Contact email for Let's Encrypt (expiry notices)."
            echo "              Defaults to admin@DOMAIN when --domain is given."
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

    # Generate random keys
    IDENTITY_HASH_KEY=$(openssl rand -hex 32)
    CAP_ADMIN_KEY=$(openssl rand -hex 32)
    ACCOUNTS_DB_PASSWORD=$(openssl rand -hex 16)
    SYNC_DB_PASSWORD=$(openssl rand -hex 16)

    sed_inplace "s/^IDENTITY_HASH_KEY=$/IDENTITY_HASH_KEY=$IDENTITY_HASH_KEY/" .env
    sed_inplace "s/^CAP_ADMIN_KEY=$/CAP_ADMIN_KEY=$CAP_ADMIN_KEY/" .env
    sed_inplace "s/^# ACCOUNTS_DB_PASSWORD=.*$/ACCOUNTS_DB_PASSWORD=$ACCOUNTS_DB_PASSWORD/" .env
    sed_inplace "s/^# SYNC_DB_PASSWORD=.*$/SYNC_DB_PASSWORD=$SYNC_DB_PASSWORD/" .env

    # Explicit site addresses (Caddy TLS mode; see caddy/Caddyfile) - keeps
    # .env self-documenting. --domain rewrites these to real hostnames.
    printf 'ACCOUNTS_SITE=:5377\n' >> .env
    printf 'SYNC_SITE=:5379\n' >> .env
    printf 'EXAMPLES_SITE=:5380\n' >> .env

    echo "Generated IDENTITY_HASH_KEY, CAP_ADMIN_KEY, and database passwords."
else
    echo ".env already exists, skipping generation."
fi

# Secrets are appended below; never leave a pre-existing .env world-readable
chmod 600 .env

# Apply --domain if provided
if [ -n "$DOMAIN" ]; then
    if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
        echo "Error: Invalid domain format: $DOMAIN"
        exit 1
    fi
    if [ -z "$ACME_EMAIL" ]; then
        ACME_EMAIL="admin@$DOMAIN"
    fi
    if [[ ! "$ACME_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]]; then
        echo "Error: Invalid email format: $ACME_EMAIL"
        exit 1
    fi
    echo "Configuring for domain: $DOMAIN"
    sed_inplace "s|^OAUTH_ISSUER=.*|OAUTH_ISSUER=https://accounts.$DOMAIN|" .env
    sed_inplace "s|^SYNC_ENDPOINT=.*|SYNC_ENDPOINT=https://sync.$DOMAIN/api/v1|" .env
    # Site addresses select Caddy's TLS mode (see caddy/Caddyfile)
    sed_inplace "/^ACCOUNTS_SITE=/d" .env
    sed_inplace "/^SYNC_SITE=/d" .env
    sed_inplace "/^ACME_EMAIL=/d" .env
    sed_inplace "/^EXAMPLES_SITE=/d" .env
    sed_inplace "/^EXAMPLES_ACCOUNTS_DOMAIN=/d" .env
    printf 'ACCOUNTS_SITE=accounts.%s\n' "$DOMAIN" >> .env
    printf 'SYNC_SITE=sync.%s\n' "$DOMAIN" >> .env
    printf 'ACME_EMAIL=%s\n' "$ACME_EMAIL" >> .env
    printf 'EXAMPLES_SITE=examples.%s\n' "$DOMAIN" >> .env
    printf 'EXAMPLES_ACCOUNTS_DOMAIN=accounts.%s\n' "$DOMAIN" >> .env
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
    # Same tag as the accounts service — keygen and server must agree on
    # the OPAQUE format, so they share the image reference. First-party
    # images track :latest for now; deliberate version pins once things
    # stabilize.
    KEYGEN_IMAGE="ghcr.io/betterbasehq/betterbase-accounts:latest"

    # Pull so a stale local :latest can't silently generate keys with an
    # older OPAQUE format than the server will run. If the pull fails we
    # continue with the local image but say so loudly.
    if ! docker pull -q "$KEYGEN_IMAGE" >/dev/null 2>&1; then
        echo "Warning: could not pull $KEYGEN_IMAGE; using local image" >&2
        docker image inspect "$KEYGEN_IMAGE" --format 'Warning: using {{.Id}}' >&2 || true
    fi

    if ! OPAQUE_SERVER_SETUP=$(docker run --rm --entrypoint /app/keygen "$KEYGEN_IMAGE"); then
        echo "Error: OPAQUE keygen failed. Check Docker image availability." >&2
        exit 1
    fi

    if [ -z "$OPAQUE_SERVER_SETUP" ]; then
        echo "Error: OPAQUE keygen produced no output." >&2
        exit 1
    fi

    # The value is written to .env, which is `source`d — keygen output is
    # container output and must be a hex blob, nothing else.
    if [[ ! "$OPAQUE_SERVER_SETUP" =~ ^[0-9a-fA-F]+$ ]]; then
        echo "Error: keygen output is not a hex blob; refusing to save." >&2
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

    # Stop CAP (and valkey) on any exit — success or failure — so a failed
    # provisioning never leaves a live admin session behind
    trap 'docker compose stop cap valkey >/dev/null 2>&1 || true' EXIT

    # We need curl inside the network — use the accounts image since it has curl
    echo "Pulling accounts image for network access..."
    docker compose pull accounts

    cap_curl() {
        docker compose run --rm --no-deps -T --entrypoint curl accounts \
            -sf --connect-timeout 5 --max-time 10 "$@"
    }

    # Login to CAP admin API. The request body is piped via stdin so the
    # admin key never appears in a process listing.
    echo "Authenticating with CAP..."
    login_response=$(jq -n --arg k "$CAP_ADMIN_KEY" '{"admin_key":$k}' \
        | cap_curl -X POST http://cap:3000/auth/login \
            -H "Content-Type: application/json" \
            -d @-) \
        || { echo "Error: CAP login request failed (check CAP_ADMIN_KEY)." >&2; exit 1; }

    session_token=$(echo "$login_response" | jq -r '.session_token')
    hashed_token=$(echo "$login_response" | jq -r '.hashed_token')

    if [ "$session_token" = "null" ] || [ -z "$session_token" ]; then
        echo "Error: Failed to authenticate with CAP." >&2
        exit 1
    fi

    if [ "$hashed_token" = "null" ] || [ -z "$hashed_token" ]; then
        echo "Error: CAP login response missing hashed_token." >&2
        exit 1
    fi

    # Create bearer auth token (base64 encoded JSON). The header goes through
    # a root-only temp file so the session token never appears in argv.
    auth_token=$(jq -n --arg t "$session_token" --arg h "$hashed_token" '{"token":$t,"hash":$h}' | base64 | tr -d '\n')
    header_file=$(mktemp)
    chmod 600 "$header_file"
    printf 'Authorization: Bearer %s\n' "$auth_token" > "$header_file"

    # Create site key. curl runs inside the accounts container, so the header
    # file has to be mounted in rather than referenced from the host.
    echo "Creating CAP site key..."
    key_response=$(docker compose run --rm --no-deps -T \
        --entrypoint curl -v "$header_file:/tmp/auth_header:ro" accounts \
        -sf --connect-timeout 5 --max-time 10 -X POST http://cap:3000/server/keys \
        -H "@/tmp/auth_header" \
        -H "Content-Type: application/json" \
        -d '{"name":"betterbase-accounts"}') \
        || { echo "Error: CAP site key request failed." >&2; rm -f "$header_file"; exit 1; }

    # End the admin session before tearing down — stopping the containers
    # alone would leave the token valid in the persisted valkey volume.
    docker compose run --rm --no-deps -T \
        --entrypoint curl -v "$header_file:/tmp/auth_header:ro" accounts \
        -sf --connect-timeout 5 --max-time 10 -X POST http://cap:3000/auth/logout \
        -H "@/tmp/auth_header" >/dev/null 2>&1 || true

    rm -f "$header_file"

    CAP_KEY_ID=$(echo "$key_response" | jq -r '.siteKey')
    CAP_SECRET=$(echo "$key_response" | jq -r '.secretKey')

    # CAP is a third-party image; treat its API output as untrusted since
    # these values are written to .env, which is `source`d below.
    for value in "$CAP_KEY_ID" "$CAP_SECRET"; do
        if [[ ! "$value" =~ ^[A-Za-z0-9_-]+$ ]]; then
            echo "Error: CAP returned an unexpected key format; refusing to save." >&2
            exit 1
        fi
    done

    sed_inplace "/^CAP_KEY_ID=$/d" .env
    sed_inplace "/^CAP_SECRET=$/d" .env
    printf 'CAP_KEY_ID=%s\n' "$CAP_KEY_ID" >> .env
    printf 'CAP_SECRET=%s\n' "$CAP_SECRET" >> .env

    echo "CAP site key created."
else
    echo "CAP credentials already configured."
fi

# ==========================================================================
# Step 4: Provision OAuth clients for the example apps
# ==========================================================================

# The examples container serves launchpad at / and each app at /<app>/.
EXAMPLES_APPS="launchpad tasks notes photos board chat passwords"

# bash 3.2 (macOS) has no ${var^^}
upper() {
    echo "$1" | tr '[:lower:]' '[:upper:]'
}

examples_clients_missing() {
    local app var
    for app in $EXAMPLES_APPS; do
        var="$(upper "$app")_CLIENT_ID"
        if [ -z "${!var:-}" ]; then
            return 0
        fi
    done
    return 1
}

if examples_clients_missing; then
    echo ""
    echo "Provisioning OAuth clients for the example apps..."

    # Creating clients needs a live accounts service (which pulls in its DB
    # and CAP). Started here and stopped again at the end of this step, so
    # setup still leaves nothing running. Re-arm the cleanup trap so an
    # interrupted provisioning also stops the accounts chain.
    trap 'docker compose stop accounts accounts-db cap valkey >/dev/null 2>&1 || true' EXIT

    echo "Starting accounts service..."
    if ! docker compose up -d --wait accounts 2>/dev/null; then
        echo "Error: accounts service did not become healthy." >&2
        exit 1
    fi

    oauth_client() {
        docker compose exec -T accounts /app/oauth-client "$@"
    }

    # "<client-id>\t<Redirect URIs line>" for an existing client name, via
    # `oauth-client list` (rows print ID: before Name:, Redirect URIs after).
    find_client() {
        oauth_client list 2>/dev/null | awk -v n="$1" \
            '$1 == "ID:" { id = $2 }
             $1 == "Name:" && $2 == n { getline; print id "\t" $0 }' \
            | head -1
    }

    # Public redirect base for the examples origin (follows EXAMPLES_SITE,
    # which --domain sets; ":5380" means localhost HTTP mode).
    if [ -n "${EXAMPLES_SITE:-}" ] && [[ "$EXAMPLES_SITE" != :* ]]; then
        REDIRECT_BASE="https://$EXAMPLES_SITE"
    else
        REDIRECT_BASE="http://localhost:${EXAMPLES_PORT:-5380}"
    fi

    for app in $EXAMPLES_APPS; do
        var="$(upper "$app")_CLIENT_ID"
        if [ -n "${!var:-}" ]; then
            echo "  $app: client already configured."
            continue
        fi

        # Launchpad lives at the root; other apps at /<app>/.
        if [ "$app" = "launchpad" ]; then
            redirect_uri="$REDIRECT_BASE/"
        else
            redirect_uri="$REDIRECT_BASE/$app/"
        fi

        scope_args=()
        case "$app" in
            photos) scope_args=(--scope sync --scope files) ;;
            launchpad) ;;
            *) scope_args=(--scope sync) ;;
        esac

        # Reuse an existing client only while its registered redirect URIs
        # still cover this deployment's origin (e.g. not after a localhost
        # -> domain migration, where reusing would silently break OAuth).
        existing="$(find_client "$app")"
        client_id=""
        if [ -n "$existing" ]; then
            existing_id="$(printf '%s' "$existing" | cut -f1)"
            if printf '%s' "$existing" | grep -q "\"$redirect_uri\""; then
                client_id="$existing_id"
                echo "  $app: reusing existing client."
            else
                echo "  $app: existing client has stale redirect URIs; creating a new one."
            fi
        fi

        if [ -z "$client_id" ]; then
            echo "Creating OAuth client for $app ($redirect_uri)..."
            # "${arr[@]+"${arr[@]}"}" keeps empty arrays usable under set -u
            # on bash 3.2 (macOS)
            output=$(oauth_client create --name "$app" \
                --redirect-uri "$redirect_uri" \
                ${scope_args[@]+"${scope_args[@]}"} 2>&1) || true
            client_id=$(echo "$output" | grep "^Client ID:" | awk '{print $3}')
        fi

        if [ -z "$client_id" ]; then
            echo "Error: could not create or find OAuth client for $app." >&2
            echo "$output" >&2
            exit 1
        fi

        # The value is written to .env (which is `source`d) - only accept
        # conservative identifier characters, as with the CAP keys above.
        if [[ ! "$client_id" =~ ^[A-Za-z0-9_-]+$ ]]; then
            echo "Error: unexpected client ID format for $app; refusing to save." >&2
            exit 1
        fi

        sed_inplace "/^$var=/d" .env
        printf '%s=%s\n' "$var" "$client_id" >> .env
        eval "$var=\$client_id"
        echo "  $app: $client_id"
    done

    # Leave nothing running (mirrors the CAP step); `docker compose up -d`
    # starts the full stack fresh.
    echo "Stopping provisioning services..."
    docker compose stop accounts accounts-db cap valkey >/dev/null 2>&1 || true

    echo "Example app OAuth clients configured."
else
    echo "Example app OAuth clients already configured."
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
    echo "  Using localhost defaults (plain HTTP on ports ${ACCOUNTS_PORT:-5377}/${SYNC_PORT:-5379}/${EXAMPLES_PORT:-5380})."
    echo "  For production, re-run with:"
    echo "    ./setup.sh --domain yourdomain.com"
    echo ""
else
    echo "  TLS: Caddy will obtain Let's Encrypt certificates for"
    echo "    ${ACCOUNTS_SITE:-accounts.$DOMAIN}"
    echo "    ${SYNC_SITE:-sync.$DOMAIN}"
    echo "    ${EXAMPLES_SITE:-examples.$DOMAIN}"
    echo "  Before starting, make sure:"
    echo "    - DNS A records for all three subdomains point to this server"
    echo "    - Ports 80 and 443 are reachable from the internet"
    echo ""
    if [[ "${SMTP_DEV_MODE:-true}" != "false" ]]; then
        echo "  Warning: SMTP_DEV_MODE is on — signup/verification emails are"
        echo "  logged (docker compose logs accounts), not delivered. Set"
        echo "  SMTP_DEV_MODE=false + SMTP_HOST for real email delivery."
        echo ""
    fi
fi
echo "To start Betterbase:"
echo "  docker compose up -d"
echo ""
echo "To check health:"
echo "  docker compose ps"
