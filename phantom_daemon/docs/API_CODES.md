# API Response Codes

All responses carry a `code` field for frontend translation. The `error` field is preserved for API consumers and debugging.

## Response Envelopes

```
// Error
{ "ok": false, "error": "Client not found: alice", "code": "CLIENT_NOT_FOUND" }

// Success — action (code inside data alongside status)
{ "ok": true, "data": { "status": "revoked", "code": "CLIENT_REVOKED" } }

// Success — data query (no code, data is self-describing)
{ "ok": true, "data": { ... } }
```

> `error` is kept with the full descriptive message for API consumers.
> `code` is the stable machine-readable key for frontend i18n.
> Action responses carry `code` inside `data`; data query responses carry no `code`.

---

## Error Codes

### Clients (`/api/core/clients/`)

| Code                         | HTTP      | Trigger                                  |
|------------------------------|-----------|------------------------------------------|
| `CLIENT_NOT_FOUND`           | 404 / 400 | Client lookup returned nothing           |
| `CLIENT_ALREADY_EXISTS`      | 400       | `WalletError` — duplicate name on assign |
| `WALLET_FULL`                | 409       | `WalletFullError` — IP pool exhausted    |
| `ENDPOINT_V4_NOT_CONFIGURED` | 400       | `WIREGUARD_ENDPOINT_V4` not set          |
| `ENDPOINT_V6_NOT_CONFIGURED` | 400       | `WIREGUARD_ENDPOINT_V6` not set          |

### WireGuard (`/api/core/wireguard/`)

| Code               | HTTP | Trigger                                   |
|--------------------|------|-------------------------------------------|
| `CLIENT_NOT_FOUND` | 404  | Client not in wallet (peer lookup)        |
| `PEER_NOT_FOUND`   | 404  | Client exists in wallet but not in WG IPC |

### Firewall (`/api/core/firewall/`)

| Code              | HTTP | Trigger                                   |
|-------------------|------|-------------------------------------------|
| `GROUP_NOT_FOUND` | 404  | `GroupNotFoundError` from firewall bridge |

### Network (`/api/core/network/`)

| Code                     | HTTP | Trigger                                                   |
|--------------------------|------|-----------------------------------------------------------|
| `CIDR_CAPACITY_EXCEEDED` | 400  | `WalletError` — new prefix too small for assigned clients |

### Multihop (`/api/multihop/`)

| Code                  | HTTP | Trigger                                          |
|-----------------------|------|--------------------------------------------------|
| `INVALID_EXIT_CONFIG` | 400  | `ValueError` — WireGuard config parse failed     |
| `EXIT_NOT_FOUND`      | 404  | Exit name not in exit store                      |
| `EXIT_ALREADY_EXISTS` | 400  | `ExitStoreError` — duplicate name on import      |
| `EXIT_IS_ACTIVE`      | 400  | `ExitStoreError` — remove attempted while active |

### Generic (Global Handler — Business Exceptions)

`error` contains the full `str(exc)` message. `code` is fixed per exception type.

| Code               | HTTP | Exception                           |
|--------------------|------|-------------------------------------|
| `WALLET_FULL`      | 409  | `WalletFullError`                   |
| `WALLET_ERROR`     | 400  | `WalletError`                       |
| `EXIT_STORE_ERROR` | 400  | `ExitStoreError`                    |
| `VALIDATION_ERROR` | 422  | `RequestValidationError` (Pydantic) |

### Generic Fallbacks (Framework `HTTPException`)

| Code                  | HTTP      |
|-----------------------|-----------|
| `BAD_REQUEST`         | 400       |
| `UNAUTHORIZED`        | 401       |
| `FORBIDDEN`           | 403       |
| `NOT_FOUND`           | 404       |
| `METHOD_NOT_ALLOWED`  | 405       |
| `CONFLICT`            | 409       |
| `VALIDATION_ERROR`    | 422       |
| `INTERNAL_ERROR`      | 500       |
| `SERVICE_UNAVAILABLE` | 502 / 503 |
| `UNKNOWN_ERROR`       | *         |

---

## Success Codes

Carried in `data.code` alongside `data.status` for action endpoints.

### Clients

| Code             | Endpoint                        | `data.status` |
|------------------|---------------------------------|---------------|
| `CLIENT_REVOKED` | `POST /api/core/clients/revoke` | `"revoked"`   |

### Multihop

| Code                        | Endpoint                     | `data.status`        |
|-----------------------------|------------------------------|----------------------|
| `MULTIHOP_ENABLED`          | `POST /api/multihop/enable`  | `"enabled"`          |
| `MULTIHOP_ALREADY_ACTIVE`   | `POST /api/multihop/enable`  | `"already_active"`   |
| `MULTIHOP_DISABLED`         | `POST /api/multihop/disable` | `"disabled"`         |
| `MULTIHOP_ALREADY_DISABLED` | `POST /api/multihop/disable` | `"already_disabled"` |
| `EXIT_REMOVED`              | `POST /api/multihop/remove`  | `"removed"`          |

