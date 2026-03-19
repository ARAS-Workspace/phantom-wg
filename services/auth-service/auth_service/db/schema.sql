-- phantom auth-service — auth.db Schema v0.2
--
-- WAL mode, foreign keys ON (set at connection level)
--
-- Bootstrap: tools/setup.sh creates DB + initial admin
-- Runtime: auth-service opens existing DB (fails if missing)

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

-- ─── Users ──────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS users (
    id            TEXT PRIMARY KEY,
    username      TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    role          TEXT NOT NULL DEFAULT 'admin',
    totp_secret   TEXT,
    created_at    TEXT NOT NULL,
    updated_at    TEXT NOT NULL
);

-- ─── TOTP Backup Codes ─────────────────────────────────────────

CREATE TABLE IF NOT EXISTS totp_backup_codes (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id   TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    code_hash TEXT NOT NULL,
    used      INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_backup_user ON totp_backup_codes(user_id);

-- ─── Sessions ───────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS sessions (
    id               TEXT PRIMARY KEY,
    user_id          TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_jti        TEXT NOT NULL UNIQUE,
    token_hash       TEXT NOT NULL,
    issued_at        TEXT NOT NULL,
    expires_at       TEXT NOT NULL,
    last_activity_at TEXT NOT NULL,
    revoked          INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_sessions_jti ON sessions(token_jti);
CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id);

-- ─── Audit Log ──────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS audit_log (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id    TEXT,
    action     TEXT NOT NULL,
    detail     TEXT NOT NULL DEFAULT '{}',
    ip_address TEXT NOT NULL DEFAULT '',
    timestamp  TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_audit_action ON audit_log(action);
CREATE INDEX IF NOT EXISTS idx_audit_ts ON audit_log(timestamp);
