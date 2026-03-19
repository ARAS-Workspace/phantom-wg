# Environment Variables

All variables are optional. Daemon exits with code 1 on startup if required secrets are missing.

## Paths

| Variable            | Default                     | Type | Description                                            |
|---------------------|-----------------------------|------|--------------------------------------------------------|
| `PHANTOM_DB_DIR`    | `/var/lib/phantom/db`       | path | SQLite database directory (wallet + exit store)        |
| `PHANTOM_STATE_DIR` | `/var/lib/phantom/state/db` | path | Bridge state directory (WireGuard, firewall) |

## WireGuard

| Variable                | Default | Type    | Description                                                                                                                |
|-------------------------|---------|---------|----------------------------------------------------------------------------------------------------------------------------|
| `WIREGUARD_LISTEN_PORT` | `51820` | int     | UDP listen port for WireGuard interface                                                                                    |
| `WIREGUARD_MTU`         | `1420`  | int     | MTU for WireGuard tunnel interface                                                                                         |
| `WIREGUARD_KEEPALIVE`   | `25`    | int (s) | Persistent keepalive interval for client peers                                                                             |
| `WIREGUARD_ENDPOINT_V4` | `""`    | string  | Server IPv4 address exposed to clients — required for `v4`/`hybrid` config export → `ENDPOINT_V4_NOT_CONFIGURED` if absent |
| `WIREGUARD_ENDPOINT_V6` | `""`    | string  | Server IPv6 address exposed to clients — required for `v6`/`hybrid` config export → `ENDPOINT_V6_NOT_CONFIGURED` if absent |

## Secrets (Docker Secrets — files, not env vars)

Read from `/run/secrets/` by `load_secrets()`. Both files must exist and contain 64-char hex strings.

| File             | Description                        |
|------------------|------------------------------------|
| `wg_private_key` | WireGuard server private key (hex) |
| `wg_public_key`  | WireGuard server public key (hex)  |

> Missing or malformed key files raise `SecretsError` → daemon exits at startup.

## Runtime (Unix Domain Socket)

| Argument      | Default                        | Description                           |
|---------------|--------------------------------|---------------------------------------|
| `sys.argv[1]` | `/var/run/phantom-daemon.sock` | UDS path passed to Uvicorn at startup |
