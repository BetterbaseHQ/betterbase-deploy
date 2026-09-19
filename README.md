# Betterbase Self-Hosting

Production deployment for Betterbase using Docker Compose.

## Quick Start

```bash
# 1. Clone this repo
git clone https://github.com/BetterbaseHQ/betterbase-deploy.git
cd betterbase-deploy

# 2. Run setup (generates .env, OPAQUE keys, and provisions CAP)
chmod +x setup.sh
./setup.sh

# For a production domain (automatic Let's Encrypt TLS):
./setup.sh --domain yourdomain.com --email you@yourdomain.com

# 3. Start services
docker compose up -d

# 4. Check health
docker compose ps
```

## TLS and Domains

Two modes, selected by `./setup.sh --domain`:

**Localhost (default)** — Caddy serves plain HTTP on ports 5377 (accounts)
and 5379 (sync). No TLS, no DNS needed. Good for trying things out.

**Production (`--domain yourdomain.com`)** — Caddy serves
`https://accounts.yourdomain.com` and `https://sync.yourdomain.com` on port
443 with automatically managed Let's Encrypt certificates, and redirects
HTTP (port 80) to HTTPS. Before starting:

- Create DNS **A records** for both `accounts.yourdomain.com` and
  `sync.yourdomain.com` pointing to your server's public IP
- Open ports **80 and 443** in your firewall (80 is required for certificate
  issuance/redirects)
- Pass `--email` so Let's Encrypt can send expiry notices (defaults to
  `admin@yourdomain.com`)

The domain also becomes the services' public identity: JWT issuer
(`OAUTH_ISSUER`), advertised sync endpoint, and OAuth redirect base all use
it. Changing the domain later invalidates previously issued tokens.

If you're behind Cloudflare or an AWS ALB, see the client-IP detection
comments in `caddy/Caddyfile`.

> **Note:** the Caddyfile is baked into the Caddy image. After pulling repo
> updates, start with `docker compose up -d --build` so changes to
> `caddy/Caddyfile` (or the Caddy build) are picked up.

## Services

| Service | Ports | Description |
|---------|-------|-------------|
| Caddy | 80, 443 (TLS mode) / 5377, 5379 (localhost mode) | Reverse proxy with rate limiting and automatic TLS |
| Accounts | (internal) | OPAQUE auth + OAuth 2.0 |
| Sync | (internal) | Encrypted blob sync |
| CAP | (internal) | Proof-of-work CAPTCHA |
| Valkey | (internal) | Redis-compatible backing store for CAP |
| PostgreSQL | (internal) | Databases for accounts and sync |

## Configuration

Copy `.env.example` to `.env` and configure:

- `OPAQUE_SERVER_SETUP` — Generated OPAQUE server key material
- `OAUTH_ISSUER` — Public URL of your accounts server
- `SYNC_ENDPOINT` — Public URL of your sync server API
- `IDENTITY_HASH_KEY` — HMAC key for privacy-preserving identity hashing
- `ACCOUNTS_SITE` / `SYNC_SITE` / `ACME_EMAIL` — TLS mode (set by `--domain`)

See `.env.example` for all options.

## License

Apache-2.0
