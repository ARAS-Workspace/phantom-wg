-- phantom-daemon wallet.db — Schema v0.5
--
-- WAL mode (autocheckpoint=1 set at connection level), foreign keys ON
--
-- Server identity (keys) → Docker secrets (/run/secrets/)
-- Operational params (port, mtu, keepalive) → environment variables
-- Persistent config (subnet, dns) → config table below
-- User data and IP pool → users table below

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

-- ─── Config (key-value, persistent) ─────────────────────────────

CREATE TABLE IF NOT EXISTS config (
    key         TEXT    PRIMARY KEY,
    value       TEXT    NOT NULL
);

-- Initial values (inserted by daemon on first boot):
--
--   ipv4_subnet      10.8.0.0/24           user-provided or default
--   ipv6_subnet      fd00:70:68::/120      calculated via terazi (immutable)
--   dns_v4           JSON                  {"primary": "9.9.9.9", "secondary": "149.112.112.112"}
--   dns_v6           JSON                  {"primary": "2620:fe::fe", "secondary": "2620:fe::9"}

-- ─── Users (IP Pool + Client Registry) ──────────────────────────

CREATE TABLE IF NOT EXISTS users (
    ipv4_address        TEXT    PRIMARY KEY,             -- pre-populated, natural key
    ipv6_address        TEXT    NOT NULL UNIQUE,         -- pre-populated, terazi paired
    id                  TEXT    UNIQUE,                  -- UUID4 hex (32 char), NULL = free slot
    name                TEXT    UNIQUE,                  -- NULL = free slot
    private_key_hex     TEXT,
    public_key_hex      TEXT,
    preshared_key_hex   TEXT,
    created_at          TEXT,                            -- ISO 8601
    updated_at          TEXT                             -- ISO 8601
);