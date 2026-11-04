# Environment Variables

All variables are optional. Defaults are production-safe except where noted.

## Server

| Variable         | Default   | Type   | Description                                                |
|------------------|-----------|--------|------------------------------------------------------------|
| `AUTH_HOST`      | `0.0.0.0` | string | Bind address                                               |
| `AUTH_PORT`      | `8443`    | int    | Listen port                                                |
| `AUTH_LOG_LEVEL` | `info`    | string | Uvicorn log level (`debug` · `info` · `warning` · `error`) |

## Paths

| Variable           | Default                 | Type | Description                                                            |
|--------------------|-------------------------|------|------------------------------------------------------------------------|
| `AUTH_DB_DIR`      | `/var/lib/phantom/auth` | path | Directory containing `auth.db` — must exist before startup             |
| `AUTH_SECRETS_DIR` | `/run/secrets`          | path | Directory containing key files (`auth_signing_key`, `auth_verify_key`) |

## Proxy

| Variable                     | Default                               | Type        | Description                                                    |
|------------------------------|---------------------------------------|-------------|----------------------------------------------------------------|
| `AUTH_PROXY_URL`             | `unix:///var/run/phantom/daemon.sock` | URL         | Daemon target. `unix://` prefix = UDS, otherwise plain HTTP    |
| `AUTH_PROXY_TIMEOUT`         | `30.0`                                | float (s)   | Per-request timeout toward daemon                              |
| `AUTH_PROXY_MAX_BODY`        | `65536`                               | int (bytes) | Max forwarded request body — exceeded → `BODY_TOO_LARGE` (413) |
| `AUTH_PROXY_BACKUP_MAX_BODY` | `67108864`                            | int (bytes) | The same limit on `/api/core/backup/*`                         |

## Token Lifetimes

| Variable                   | Default | Type    | Description                                                              |
|----------------------------|---------|---------|--------------------------------------------------------------------------|
| `AUTH_TOKEN_LIFETIME`      | `86400` | int (s) | Access token validity (24 h)                                             |
| `AUTH_INACTIVITY_TIMEOUT`  | `1800`  | int (s) | Session invalidated after this idle period (30 min) → `SESSION_INACTIVE` |
| `AUTH_MFA_TOKEN_LIFETIME`  | `120`   | int (s) | MFA pending token + password change token validity (2 min)               |
| `AUTH_TOTP_SETUP_LIFETIME` | `300`   | int (s) | TOTP setup token validity (5 min)                                        |

## Rate Limiting

| Variable                 | Default          | Type      | Description                                                  |
|--------------------------|------------------|-----------|--------------------------------------------------------------|
| `AUTH_RATE_LIMIT_WINDOW` | `60`             | int (s)   | Sliding window duration                                      |
| `AUTH_RATE_LIMIT_MAX`    | `5`              | int       | Max attempts within window — exceeded → `RATE_LIMITED` (429) |
| `PHANTOM_SUBNET_V4`      | `172.28.0.0/24`  | CIDR      | IPv4 subnet of `phantom-net`, trusted for `X-Forwarded-For`  |
| `PHANTOM_SUBNET_V6`      | `fd00:d0ce::/64` | CIDR      | IPv6 subnet of `phantom-net`, trusted for `X-Forwarded-For`  |
| `AUTH_TRUSTED_PROXIES`   | empty            | CIDR list | Additional trusted peers (comma-separated)                   |

> Rate limiting applies to `POST /auth/login`, `POST /auth/mfa/verify` and
> `POST /auth/totp/backup`, keyed by client IP and sharing one budget. The
> limiter resets only after *completed* authentication — a correct password
> with MFA still pending does not refill the budget.
>
> Client IP resolution: `X-Forwarded-For` is honored only when the
> connecting peer is inside a trusted network: `PHANTOM_SUBNET_V4`,
> `PHANTOM_SUBNET_V6` and, when set, `AUTH_TRUSTED_PROXIES`. The two subnets
> are the variables `networks.phantom-net.ipam` reads in the daemon compose
> — where nginx lives — and their defaults are the compose defaults; an
> empty value takes the default. `AUTH_TRUSTED_PROXIES` adds to the subnets
> and does not replace them. Entries are walked right to left, skipping
> trusted hops; the first untrusted address is the client. A direct
> connection cannot spoof its own address.
