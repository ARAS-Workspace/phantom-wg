from __future__ import annotations

import os
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient
from nacl.signing import SigningKey, VerifyKey

from auth_service.app import create_app
from auth_service.config import AuthConfig
from auth_service.crypto.jwt import encode_token, token_hash
from auth_service.crypto.keys import AuthSigningKeys
from auth_service.crypto.password import hash_password
from auth_service.db.repository import AuthDB, UserRow, bootstrap_auth_db
from auth_service.middleware.rate_limit import RateLimiter


@dataclass
class AuthTestEnvironment:
    """Semantically isolated test environment.

    Encapsulates all auth-service state for a single test session:
    crypto keys, database, config, and convenience helpers.
    """

    config: AuthConfig
    keys: AuthSigningKeys
    signing_key: SigningKey
    verify_key: VerifyKey
    db: AuthDB
    db_path: str
    db_dir: str
    rate_limiter: RateLimiter

    # ── User helpers ─────────────────────────────────────────────

    def create_user(self, username: str, password: str, role: str = "admin") -> UserRow:
        """Create a user with plaintext password (hashed internally)."""
        return self.db.create_user(username, hash_password(password), role=role)

    # ── Session helpers ──────────────────────────────────────────

    def issue_token(self, username: str, lifetime: int | None = None) -> str:
        """Issue a valid access JWT + DB session for an existing user."""
        user = self.db.get_user_by_username(username)
        if user is None:
            raise ValueError(f"User not found: {username}")

        lt = lifetime or self.config.token_lifetime
        jti = uuid.uuid4().hex
        token = encode_token(self.signing_key, sub=username, jti=jti, lifetime=lt, extra={"role": user.role})

        now = datetime.now(UTC)
        self.db.create_session(
            user_id=user.id,
            token_jti=jti,
            token_hash=token_hash(token),
            issued_at=now.isoformat(),
            expires_at=(now + timedelta(seconds=lt)).isoformat(),
        )
        return token

    def login(self, username: str, password: str) -> str:
        """Full login via HTTP — returns access token string."""
        client = self.make_client()
        resp = client.post("/auth/login", json={"username": username, "password": password})
        assert resp.status_code == 200, resp.json()
        return resp.json()["data"]["token"]

    # ── TOTP helpers ────────────────────────────────────────────

    def enable_totp(self, _username: str, password: str, token: str) -> dict:
        """Full TOTP enable via setup + confirm. Returns setup response data."""
        client = self.make_client()
        # Step 1: setup
        resp = client.post(
            "/auth/totp/setup",
            json={"password": password},
            headers=self.bearer(token),
        )
        assert resp.status_code == 200, resp.json()
        setup_data = resp.json()["data"]
        secret = setup_data["secret"]
        setup_token = setup_data["setup_token"]

        # Generate valid TOTP code from secret
        import base64
        import hashlib
        import hmac as hmac_mod
        import struct
        import time as time_mod
        key = base64.b32decode(secret)
        counter = struct.pack(">Q", int(time_mod.time()) // 30)
        mac = hmac_mod.new(key, counter, hashlib.sha1).digest()
        offset = mac[-1] & 0x0F
        truncated = struct.unpack(">I", mac[offset:offset + 4])[0] & 0x7FFFFFFF
        code = str(truncated % (10 ** 6)).zfill(6)

        # Step 2: confirm
        resp2 = client.post(
            "/auth/totp/confirm",
            json={"setup_token": setup_token, "code": code},
            headers=self.bearer(token),
        )
        assert resp2.status_code == 200, resp2.json()
        return setup_data

    # ── Client factory ───────────────────────────────────────────

    def make_client(
        self,
        proxy_client=None,
        rate_limiter: RateLimiter | None = None,
    ) -> TestClient:
        """Build a TestClient wired to this environment's state."""
        app = create_app(lifespan_func=None)
        app.state.config = self.config
        app.state.keys = self.keys
        app.state.signing_key = self.signing_key
        app.state.verify_key = self.verify_key
        app.state.db_path = self.db_path
        app.state.rate_limiter = rate_limiter or self.rate_limiter
        app.state.proxy_client = proxy_client
        return TestClient(app)

    # ── Header helper ────────────────────────────────────────────

    @staticmethod
    def bearer(token: str) -> dict[str, str]:
        """Return Authorization header dict."""
        return {"Authorization": f"Bearer {token}"}


@pytest.fixture()
def auth_env(tmp_path):
    """Create a fully isolated auth test environment per test."""
    sk = SigningKey.generate()
    vk = sk.verify_key
    signing_hex = sk.encode().hex()
    verify_hex = vk.encode().hex()

    db_dir = str(tmp_path / "auth-db")
    secrets_dir = str(tmp_path / "secrets")
    os.makedirs(secrets_dir, exist_ok=True)

    with open(os.path.join(secrets_dir, "auth_signing_key"), "w") as f:
        f.write(signing_hex)
    with open(os.path.join(secrets_dir, "auth_verify_key"), "w") as f:
        f.write(verify_hex)

    config = AuthConfig(
        host="127.0.0.1",
        port=8443,
        log_level="warning",
        proxy_url="unix:///tmp/phantom-test.sock",
        db_dir=db_dir,
        secrets_dir=secrets_dir,
        token_lifetime=3600,
        inactivity_timeout=1800,
        mfa_token_lifetime=300,
        totp_setup_lifetime=300,
        proxy_timeout=10.0,
        proxy_max_body=65536,
        proxy_backup_max_body=131072,
        rate_limit_window=60,
        rate_limit_max=5,
    )

    keys = AuthSigningKeys(signing_key_hex=signing_hex, verify_key_hex=verify_hex)
    db, db_path = bootstrap_auth_db(db_dir=db_dir)
    rate_limiter = RateLimiter(window=60, max_attempts=5)

    env = AuthTestEnvironment(
        config=config,
        keys=keys,
        signing_key=sk,
        verify_key=vk,
        db=db,
        db_path=db_path,
        db_dir=db_dir,
        rate_limiter=rate_limiter,
    )
    yield env
    db.close()
