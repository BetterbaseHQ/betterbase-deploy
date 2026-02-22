# Betterbase Self-Hosting

Production deployment for Betterbase using Docker Compose.

## Quick Start

```bash
# 1. Clone this repo
git clone https://github.com/BetterbaseHQ/betterbase-deploy.git
cd betterbase-deploy

# 2. Run setup (generates .env with random keys)
chmod +x setup.sh
./setup.sh

# 3. Configure OPAQUE keys
docker run --rm ghcr.io/betterbasehq/betterbase-accounts keygen >> .env

# 4. Start services
docker compose up -d

# 5. Check health
docker compose ps
```

## Services

| Service | Port | Description |
|---------|------|-------------|
| Caddy | 5377, 5379 | Reverse proxy with rate limiting |
| Accounts | (internal) | OPAQUE auth + OAuth 2.0 |
| Sync | (internal) | Encrypted blob sync |
| CAP | (internal) | Proof-of-work CAPTCHA |
| PostgreSQL | (internal) | Databases for accounts and sync |

## Configuration

Copy `.env.example` to `.env` and configure:

- `OPAQUE_SERVER_SETUP` — Generated OPAQUE server key material
- `OAUTH_ISSUER` — Public URL of your accounts server
- `SYNC_ENDPOINT` — Public URL of your sync server API
- `IDENTITY_HASH_KEY` — HMAC key for privacy-preserving identity hashing

See `.env.example` for all options.

## License

Apache-2.0
