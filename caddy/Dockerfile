# Build Caddy with rate limiting plugin
FROM caddy:2-builder AS builder

RUN xcaddy build \
    --with github.com/mholt/caddy-ratelimit

FROM caddy:2

COPY --from=builder /usr/bin/caddy /usr/bin/caddy

# Caddyfile is bind-mounted at runtime (see docker-compose.yml), so config
# edits only need a `docker compose restart caddy` — never an image rebuild.
