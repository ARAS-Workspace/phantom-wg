from __future__ import annotations

import base64
import hashlib
import hmac
import struct
import time

from auth_service.crypto.totp import generate_secret
from auth_service.middleware.rate_limit import RateLimiter


def _totp_code(secret: str) -> str:
    key = base64.b32decode(secret)
    counter = struct.pack(">Q", int(time.time()) // 30)
    mac = hmac.new(key, counter, hashlib.sha1).digest()
    offset = mac[-1] & 0x0F
    truncated = struct.unpack(">I", mac[offset:offset + 4])[0] & 0x7FFFFFFF
    return str(truncated % 1000000).zfill(6)


def test_rate_limit_blocks_login_endpoint(auth_env):
    client = auth_env.make_client(rate_limiter=RateLimiter(window=60, max_attempts=2))
    for _ in range(2):
        client.post("/auth/login", json={"username": "x", "password": "y"})
    resp = client.post("/auth/login", json={"username": "x", "password": "y"})
    assert resp.status_code == 429


def test_rate_limit_blocks_mfa_verify_endpoint(auth_env):
    client = auth_env.make_client(rate_limiter=RateLimiter(window=60, max_attempts=2))
    for _ in range(2):
        client.post("/auth/mfa/verify", json={"mfa_token": "x", "code": "000000"})
    resp = client.post("/auth/mfa/verify", json={"mfa_token": "x", "code": "000000"})
    assert resp.status_code == 429


def test_rate_limit_blocks_backup_code_endpoint(auth_env):
    client = auth_env.make_client(rate_limiter=RateLimiter(window=60, max_attempts=2))
    for _ in range(2):
        client.post("/auth/totp/backup", json={"mfa_token": "x", "code": "00000000"})
    resp = client.post("/auth/totp/backup", json={"mfa_token": "x", "code": "00000000"})
    assert resp.status_code == 429


def test_correct_password_does_not_reset_budget_mid_mfa(auth_env):
    """Knowing the password must not refill the TOTP brute-force budget."""
    user = auth_env.create_user("mfabudget", "mfapass12")
    auth_env.db.set_totp_secret(user.id, generate_secret())
    client = auth_env.make_client(rate_limiter=RateLimiter(window=60, max_attempts=3))

    for _ in range(2):
        client.post("/auth/login", json={"username": "mfabudget", "password": "wrong"})
    resp = client.post("/auth/login", json={"username": "mfabudget", "password": "mfapass12"})
    assert resp.status_code == 200  # MFA challenge — not authenticated yet

    # All 3 attempts consumed; the correct password reset nothing.
    resp = client.post("/auth/mfa/verify", json={"mfa_token": "x", "code": "000000"})
    assert resp.status_code == 429


def test_full_mfa_auth_resets_budget(auth_env):
    """Only completed authentication (password + TOTP) resets the limiter."""
    user = auth_env.create_user("mfareset", "mfapass12")
    secret = generate_secret()
    auth_env.db.set_totp_secret(user.id, secret)
    client = auth_env.make_client(rate_limiter=RateLimiter(window=60, max_attempts=3))

    resp = client.post("/auth/login", json={"username": "mfareset", "password": "mfapass12"})
    mfa_token = resp.json()["data"]["mfa_token"]
    resp = client.post("/auth/mfa/verify", json={"mfa_token": mfa_token, "code": _totp_code(secret)})
    assert resp.status_code == 200

    # Budget was reset on success: three fresh attempts all reach auth.
    for _ in range(3):
        resp = client.post("/auth/login", json={"username": "mfareset", "password": "wrong"})
        assert resp.status_code == 401
