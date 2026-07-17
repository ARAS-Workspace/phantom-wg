# API Response Codes

All responses use a code-only envelope. 

## Response Envelopes

```
// Success with data
{ "ok": true, "data": { ... } }

// Success action (no domain data)
{ "ok": true, "data": { "success_code": "LOGGED_OUT" } }

// Error
{ "ok": false, "error_code": "INVALID_CREDENTIALS" }
```

> **Rule:** `data.message` is forbidden. `error.detail` strings are forbidden.
> Internal exception messages (`AuthTokenInvalidError("...")`) are developer-only context — never serialized.

---

## Error Codes

### Authentication

| Code                  | HTTP | Trigger                                             |
|-----------------------|------|-----------------------------------------------------|
| `INVALID_CREDENTIALS` | 401  | Wrong username or password                          |
| `RATE_LIMITED`        | 429  | Login/MFA attempts exceeded                         |
| `INVALID_MFA_STATE`   | 401  | MFA token references non-existent or TOTP-less user |
| `INVALID_TOTP_CODE`   | 401  | Wrong TOTP code                                     |
| `INVALID_BACKUP_CODE` | 401  | Wrong or already-used backup code                   |

### Token & Session

| Code                     | HTTP | Trigger                                                           |
|--------------------------|------|-------------------------------------------------------------------|
| `TOKEN_EXPIRED`          | 401  | `AuthTokenExpiredError` — token past `exp`                        |
| `TOKEN_INVALID`          | 401  | `AuthTokenInvalidError` — malformed, bad signature, missing claim |
| `MISSING_AUTH_HEADER`    | 401  | No `Authorization: Bearer` header                                 |
| `INVALID_TOKEN_TYPE`     | 401  | Token `typ` is not `access`                                       |
| `TOKEN_MISMATCH`         | 401  | Stored hash does not match presented token                        |
| `TOKEN_SUBJECT_MISMATCH` | 401  | Setup/change token `sub` ≠ authenticated user                     |
| `SESSION_REVOKED`        | 401  | Session revoked or not found                                      |
| `SESSION_INACTIVE`       | 401  | Inactivity timeout exceeded                                       |

### TOTP Management

| Code                         | HTTP | Trigger                                             |
|------------------------------|------|-----------------------------------------------------|
| `TOTP_ALREADY_ENABLED`       | 409  | Setup/confirm attempted when TOTP is active         |
| `TOTP_NOT_ENABLED`           | 400  | Disable attempted when TOTP is inactive             |
| `CANNOT_DISABLE_OTHERS_TOTP` | 403  | Non-superadmin targeting another user               |
| `INVALID_SETUP_TOKEN`        | 401  | Token `typ` is not `totp_setup`                     |
| `INVALID_SETUP_CLAIMS`       | 401  | Setup token missing `totp_secret` or `backup_codes` |

### Password

| Code                            | HTTP | Trigger                               |
|---------------------------------|------|---------------------------------------|
| `INVALID_PASSWORD`              | 401  | Password verification failed          |
| `INVALID_CHANGE_TOKEN`          | 401  | Token `typ` is not `password_change`  |
| `PASSWORD_MUST_DIFFER`          | 400  | New password equals current password  |
| `CANNOT_CHANGE_OTHERS_PASSWORD` | 403  | Non-superadmin targeting another user |

### User Management

| Code                  | HTTP | Trigger                                   |
|-----------------------|------|-------------------------------------------|
| `USER_NOT_FOUND`      | 404  | Username lookup returned nothing          |
| `USER_ALREADY_EXISTS` | 409  | `AuthDatabaseError` on duplicate username |
| `CANNOT_DELETE_SELF`  | 400  | Superadmin attempting self-deletion       |
| `SUPERADMIN_REQUIRED` | 403  | Role is not `superadmin`                  |

### Proxy

| Code                  | HTTP | Trigger                               |
|-----------------------|------|---------------------------------------|
| `BODY_TOO_LARGE`      | 413  | Request body exceeds `proxy_max_body` |
| `SERVICE_UNAVAILABLE` | 502  | Daemon connection failed              |

### Generic Fallbacks (framework-level)

| Code                 | HTTP |
|----------------------|------|
| `VALIDATION_ERROR`   | 422  |
| `BAD_REQUEST`        | 400  |
| `UNAUTHORIZED`       | 401  |
| `FORBIDDEN`          | 403  |
| `NOT_FOUND`          | 404  |
| `METHOD_NOT_ALLOWED` | 405  |
| `CONFLICT`           | 409  |
| `TOO_MANY_REQUESTS`  | 429  |
| `INTERNAL_ERROR`     | 500  |
| `UNKNOWN_ERROR`      | *    |

> Generic fallbacks are emitted by the global `HTTPException` handler for framework-raised errors that bypass `ApiException`.

---

## Success Codes

Returned as `{ "ok": true, "data": { "success_code": "..." } }` for action endpoints that carry no domain data.

| Code               | Endpoint                                                              |
|--------------------|-----------------------------------------------------------------------|
| `LOGGED_OUT`       | `POST /auth/logout`                                                   |
| `PASSWORD_CHANGED` | `POST /auth/password/change` · `POST /auth/users/{username}/password` |
| `TOTP_ENABLED`     | `POST /auth/totp/confirm`                                             |
| `TOTP_DISABLED`    | `POST /auth/totp/disable`                                             |
| `USER_DELETED`     | `DELETE /auth/users/{username}`                                       |

---

## Token Error Hierarchy

```
AuthTokenError          (base — never raised directly)
├── AuthTokenExpiredError   → TOKEN_EXPIRED
└── AuthTokenInvalidError   → TOKEN_INVALID
```

Raised in `crypto/jwt.py`, caught in routes and middleware with ordered `except` clauses:

```
except AuthTokenExpiredError:
    raise ApiException(401, "TOKEN_EXPIRED")
except AuthTokenInvalidError:
    raise ApiException(401, "TOKEN_INVALID")
```