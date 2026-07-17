from __future__ import annotations

from auth_service.crypto.totp import generate_secret, hash_backup_code


# ── Login ────────────────────────────────────────────────────────


def test_login_success(auth_env):
    auth_env.create_user("testuser", "testpass1")
    client = auth_env.make_client()
    resp = client.post("/auth/login", json={"username": "testuser", "password": "testpass1"})
    assert resp.status_code == 200
    data = resp.json()
    assert data["ok"] is True
    assert "token" in data["data"]
    assert data["data"]["expires_in"] == 3600


def test_login_wrong_password(auth_env):
    auth_env.create_user("wrongpw", "correct1")
    client = auth_env.make_client()
    resp = client.post("/auth/login", json={"username": "wrongpw", "password": "incorrect"})
    assert resp.status_code == 401
    assert resp.json()["ok"] is False


def test_login_nonexistent_user(auth_env):
    client = auth_env.make_client()
    resp = client.post("/auth/login", json={"username": "ghost", "password": "pass"})
    assert resp.status_code == 401


# ── Me / Logout ──────────────────────────────────────────────────


def test_me(auth_env):
    auth_env.create_user("meuser", "mepass123")
    token = auth_env.login("meuser", "mepass123")
    client = auth_env.make_client()
    resp = client.get("/auth/me", headers=auth_env.bearer(token))
    assert resp.status_code == 200
    assert resp.json()["data"]["username"] == "meuser"
    assert resp.json()["data"]["totp_enabled"] is False


def test_me_no_auth(auth_env):
    client = auth_env.make_client()
    resp = client.get("/auth/me")
    assert resp.status_code == 401


def test_logout_revokes_token(auth_env):
    auth_env.create_user("logoutuser", "logpass12")
    token = auth_env.login("logoutuser", "logpass12")
    client = auth_env.make_client()
    resp = client.post("/auth/logout", headers=auth_env.bearer(token))
    assert resp.status_code == 200
    resp = client.get("/auth/me", headers=auth_env.bearer(token))
    assert resp.status_code == 401


# ── User Management ─────────────────────────────────────────────


def test_create_user(auth_env):
    auth_env.create_user("admin", "adminpass1", role="superadmin")
    token = auth_env.login("admin", "adminpass1")
    client = auth_env.make_client()
    resp = client.post(
        "/auth/users",
        json={"username": "newuser", "password": "NewPass123!"},
        headers=auth_env.bearer(token),
    )
    assert resp.status_code == 200
    assert resp.json()["data"]["username"] == "newuser"


def test_list_users(auth_env):
    auth_env.create_user("admin", "adminpass1", role="superadmin")
    token = auth_env.login("admin", "adminpass1")
    client = auth_env.make_client()
    resp = client.get("/auth/users", headers=auth_env.bearer(token))
    assert resp.status_code == 200
    assert isinstance(resp.json()["data"], list)


def test_delete_user(auth_env):
    auth_env.create_user("admin", "adminpass1", role="superadmin")
    auth_env.create_user("todelete", "del12345")
    token = auth_env.login("admin", "adminpass1")
    client = auth_env.make_client()
    resp = client.delete("/auth/users/todelete", headers=auth_env.bearer(token))
    assert resp.status_code == 200


def test_delete_self_forbidden(auth_env):
    auth_env.create_user("admin", "adminpass1", role="superadmin")
    token = auth_env.login("admin", "adminpass1")
    client = auth_env.make_client()
    resp = client.delete("/auth/users/admin", headers=auth_env.bearer(token))
    assert resp.status_code == 400
    assert resp.json()["error_code"] == "CANNOT_DELETE_SELF"


def test_change_password(auth_env):
    auth_env.create_user("chpw", "oldpass12")
    token = auth_env.login("chpw", "oldpass12")
    client = auth_env.make_client()
    resp = client.post(
        "/auth/users/chpw/password",
        json={"password": "NewPass123!"},
        headers=auth_env.bearer(token),
    )
    assert resp.status_code == 200


def test_create_user_duplicate(auth_env):
    auth_env.create_user("admin", "adminpass1", role="superadmin")
    auth_env.create_user("dup", "duppass12")
    token = auth_env.login("admin", "adminpass1")
    client = auth_env.make_client()
    resp = client.post(
        "/auth/users",
        json={"username": "dup", "password": "DupPass12!"},
        headers=auth_env.bearer(token),
    )
    assert resp.status_code == 409


# ── MFA Login Flow ───────────────────────────────────────────────


def test_login_with_totp_returns_mfa_required(auth_env):
    user = auth_env.create_user("mfauser", "mfapass12")
    secret = generate_secret()
    auth_env.db.set_totp_secret(user.id, secret)

    client = auth_env.make_client()
    resp = client.post("/auth/login", json={"username": "mfauser", "password": "mfapass12"})
    assert resp.status_code == 200
    data = resp.json()["data"]
    assert data["mfa_required"] is True
    assert "mfa_token" in data


def test_mfa_verify_success(auth_env):
    import base64, hashlib, hmac, struct, time

    user = auth_env.create_user("mfaver", "mfapass12")
    secret = generate_secret()
    auth_env.db.set_totp_secret(user.id, secret)

    client = auth_env.make_client()
    resp = client.post("/auth/login", json={"username": "mfaver", "password": "mfapass12"})
    mfa_token = resp.json()["data"]["mfa_token"]

    # Generate valid TOTP code
    key = base64.b32decode(secret)
    counter = struct.pack(">Q", int(time.time()) // 30)
    mac = hmac.new(key, counter, hashlib.sha1).digest()
    offset = mac[-1] & 0x0F
    truncated = struct.unpack(">I", mac[offset : offset + 4])[0] & 0x7FFFFFFF
    code = str(truncated % 1000000).zfill(6)

    resp = client.post("/auth/mfa/verify", json={"mfa_token": mfa_token, "code": code})
    assert resp.status_code == 200
    assert "token" in resp.json()["data"]


def test_mfa_backup_code_login(auth_env):
    user = auth_env.create_user("mfaback", "mfapass12")
    secret = generate_secret()
    auth_env.db.set_totp_secret(user.id, secret)

    backup_code = "testback"
    auth_env.db.store_backup_codes(user.id, [hash_backup_code(backup_code)])

    client = auth_env.make_client()
    resp = client.post("/auth/login", json={"username": "mfaback", "password": "mfapass12"})
    mfa_token = resp.json()["data"]["mfa_token"]

    resp = client.post("/auth/totp/backup", json={"mfa_token": mfa_token, "code": backup_code})
    assert resp.status_code == 200
    assert "token" in resp.json()["data"]


def test_mfa_backup_code_single_use(auth_env):
    user = auth_env.create_user("mfaonce", "mfapass12")
    secret = generate_secret()
    auth_env.db.set_totp_secret(user.id, secret)

    backup_code = "onceonly"
    auth_env.db.store_backup_codes(user.id, [hash_backup_code(backup_code)])

    client = auth_env.make_client()

    # First use — success
    resp = client.post("/auth/login", json={"username": "mfaonce", "password": "mfapass12"})
    mfa_token = resp.json()["data"]["mfa_token"]
    resp = client.post("/auth/totp/backup", json={"mfa_token": mfa_token, "code": backup_code})
    assert resp.status_code == 200

    # Second use — fail
    resp = client.post("/auth/login", json={"username": "mfaonce", "password": "mfapass12"})
    mfa_token2 = resp.json()["data"]["mfa_token"]
    resp = client.post("/auth/totp/backup", json={"mfa_token": mfa_token2, "code": backup_code})
    assert resp.status_code == 401


# ── TOTP Enable / Disable ───────────────────────────────────────


def test_totp_setup_returns_token_and_secret(auth_env):
    auth_env.create_user("totpuser", "totppass1")
    token = auth_env.login("totpuser", "totppass1")
    client = auth_env.make_client()
    resp = client.post(
        "/auth/totp/setup",
        json={"password": "totppass1"},
        headers=auth_env.bearer(token),
    )
    assert resp.status_code == 200
    data = resp.json()["data"]
    assert "setup_token" in data
    assert "secret" in data
    assert "uri" in data
    assert len(data["backup_codes"]) == 8
    assert data["expires_in"] == 300
    # TOTP should NOT be enabled yet
    resp = client.get("/auth/me", headers=auth_env.bearer(token))
    assert resp.json()["data"]["totp_enabled"] is False


def test_totp_setup_wrong_password(auth_env):
    auth_env.create_user("totpwpw", "totppass1")
    token = auth_env.login("totpwpw", "totppass1")
    client = auth_env.make_client()
    resp = client.post(
        "/auth/totp/setup",
        json={"password": "wrongpass1"},
        headers=auth_env.bearer(token),
    )
    assert resp.status_code == 401


def test_totp_confirm_activates(auth_env):
    auth_env.create_user("totpconf", "totppass1")
    token = auth_env.login("totpconf", "totppass1")
    auth_env.enable_totp("totpconf", "totppass1", token)
    # Verify TOTP is now enabled
    client = auth_env.make_client()
    resp = client.get("/auth/me", headers=auth_env.bearer(token))
    assert resp.json()["data"]["totp_enabled"] is True


def test_totp_confirm_wrong_code(auth_env):
    auth_env.create_user("totpbad", "totppass1")
    token = auth_env.login("totpbad", "totppass1")
    client = auth_env.make_client()
    resp = client.post(
        "/auth/totp/setup",
        json={"password": "totppass1"},
        headers=auth_env.bearer(token),
    )
    setup_token = resp.json()["data"]["setup_token"]
    resp = client.post(
        "/auth/totp/confirm",
        json={"setup_token": setup_token, "code": "000000"},
        headers=auth_env.bearer(token),
    )
    assert resp.status_code == 401
    # TOTP should still be disabled
    resp = client.get("/auth/me", headers=auth_env.bearer(token))
    assert resp.json()["data"]["totp_enabled"] is False


def test_totp_setup_already_enabled(auth_env):
    auth_env.create_user("totpdup", "totppass1")
    token = auth_env.login("totpdup", "totppass1")
    auth_env.enable_totp("totpdup", "totppass1", token)
    client = auth_env.make_client()
    resp = client.post(
        "/auth/totp/setup",
        json={"password": "totppass1"},
        headers=auth_env.bearer(token),
    )
    assert resp.status_code == 409


def test_totp_disable(auth_env):
    auth_env.create_user("totpdis", "totppass1")
    token = auth_env.login("totpdis", "totppass1")
    auth_env.enable_totp("totpdis", "totppass1", token)
    client = auth_env.make_client()
    resp = client.post(
        "/auth/totp/disable",
        json={"password": "totppass1"},
        headers=auth_env.bearer(token),
    )
    assert resp.status_code == 200
    resp = client.get("/auth/me", headers=auth_env.bearer(token))
    assert resp.json()["data"]["totp_enabled"] is False


def test_totp_disable_wrong_password(auth_env):
    auth_env.create_user("totpwrg", "totppass1")
    token = auth_env.login("totpwrg", "totppass1")
    auth_env.enable_totp("totpwrg", "totppass1", token)
    client = auth_env.make_client()
    resp = client.post(
        "/auth/totp/disable",
        json={"password": "wrongpass1"},
        headers=auth_env.bearer(token),
    )
    assert resp.status_code == 401


# ── Password Change (2-step) ──────────────────────────────────


def test_password_verify_returns_change_token(auth_env):
    auth_env.create_user("pwver", "pwverify1")
    token = auth_env.login("pwver", "pwverify1")
    client = auth_env.make_client()
    resp = client.post(
        "/auth/password/verify",
        json={"password": "pwverify1"},
        headers=auth_env.bearer(token),
    )
    assert resp.status_code == 200
    data = resp.json()["data"]
    assert "change_token" in data
    assert data["expires_in"] > 0


def test_password_verify_wrong_password(auth_env):
    auth_env.create_user("pwwrong", "pwverify1")
    token = auth_env.login("pwwrong", "pwverify1")
    client = auth_env.make_client()
    resp = client.post(
        "/auth/password/verify",
        json={"password": "wrongpass1"},
        headers=auth_env.bearer(token),
    )
    assert resp.status_code == 401


def test_password_change_with_token(auth_env):
    auth_env.create_user("pwchange", "oldpw1234")
    token = auth_env.login("pwchange", "oldpw1234")
    client = auth_env.make_client()
    # Step 1: verify
    resp = client.post(
        "/auth/password/verify",
        json={"password": "oldpw1234"},
        headers=auth_env.bearer(token),
    )
    change_token = resp.json()["data"]["change_token"]
    # Step 2: change
    resp = client.post(
        "/auth/password/change",
        json={"change_token": change_token, "password": "NewPw1234!"},
        headers=auth_env.bearer(token),
    )
    assert resp.status_code == 200
    # Verify login with new password
    client2 = auth_env.make_client()
    resp = client2.post("/auth/login", json={"username": "pwchange", "password": "NewPw1234!"})
    assert resp.status_code == 200


def test_password_change_expired_token(auth_env):
    import time
    auth_env.create_user("pwexp", "oldpw1234")
    token = auth_env.login("pwexp", "oldpw1234")
    client = auth_env.make_client()
    # Create a change token with 1s lifetime
    from auth_service.crypto.jwt import encode_token
    change_token = encode_token(
        auth_env.signing_key, sub="pwexp", jti="test", lifetime=1, typ="password_change",
    )
    time.sleep(2)
    resp = client.post(
        "/auth/password/change",
        json={"change_token": change_token, "password": "NewPw1234!"},
        headers=auth_env.bearer(token),
    )
    assert resp.status_code == 401


def test_password_change_weak_password(auth_env):
    auth_env.create_user("pwweak", "oldpw1234")
    token = auth_env.login("pwweak", "oldpw1234")
    client = auth_env.make_client()
    resp = client.post(
        "/auth/password/verify",
        json={"password": "oldpw1234"},
        headers=auth_env.bearer(token),
    )
    change_token = resp.json()["data"]["change_token"]
    resp = client.post(
        "/auth/password/change",
        json={"change_token": change_token, "password": "weak"},
        headers=auth_env.bearer(token),
    )
    assert resp.status_code == 422


def test_password_change_same_password_rejected(auth_env):
    auth_env.create_user("pwsame", "OldPw1234!")
    token = auth_env.login("pwsame", "OldPw1234!")
    client = auth_env.make_client()
    resp = client.post(
        "/auth/password/verify",
        json={"password": "OldPw1234!"},
        headers=auth_env.bearer(token),
    )
    change_token = resp.json()["data"]["change_token"]
    resp = client.post(
        "/auth/password/change",
        json={"change_token": change_token, "password": "OldPw1234!"},
        headers=auth_env.bearer(token),
    )
    assert resp.status_code == 400
    assert resp.json()["error_code"] == "PASSWORD_MUST_DIFFER"


def test_password_change_revokes_sessions(auth_env):
    auth_env.create_user("pwrevoke", "oldpw1234")
    token = auth_env.login("pwrevoke", "oldpw1234")
    client = auth_env.make_client()
    # Verify current session works
    resp = client.get("/auth/me", headers=auth_env.bearer(token))
    assert resp.status_code == 200
    # Change password
    resp = client.post(
        "/auth/password/verify",
        json={"password": "oldpw1234"},
        headers=auth_env.bearer(token),
    )
    change_token = resp.json()["data"]["change_token"]
    resp = client.post(
        "/auth/password/change",
        json={"change_token": change_token, "password": "NewRevoke1!"},
        headers=auth_env.bearer(token),
    )
    assert resp.status_code == 200
    # Old token should be revoked
    resp = client.get("/auth/me", headers=auth_env.bearer(token))
    assert resp.status_code == 401


# ── RBAC: superadmin vs admin ─────────────────────────────────


def test_admin_cannot_create_user(auth_env):
    auth_env.create_user("regadmin", "adminpw12")
    token = auth_env.login("regadmin", "adminpw12")
    client = auth_env.make_client()
    resp = client.post(
        "/auth/users",
        json={"username": "blocked", "password": "Blocked123!"},
        headers=auth_env.bearer(token),
    )
    assert resp.status_code == 403


def test_admin_cannot_list_users(auth_env):
    auth_env.create_user("regadmin2", "adminpw12")
    token = auth_env.login("regadmin2", "adminpw12")
    client = auth_env.make_client()
    resp = client.get("/auth/users", headers=auth_env.bearer(token))
    assert resp.status_code == 403


def test_admin_cannot_delete_user(auth_env):
    auth_env.create_user("regadmin3", "adminpw12")
    auth_env.create_user("victim", "victimpw1")
    token = auth_env.login("regadmin3", "adminpw12")
    client = auth_env.make_client()
    resp = client.delete("/auth/users/victim", headers=auth_env.bearer(token))
    assert resp.status_code == 403


def test_admin_cannot_change_other_password(auth_env):
    auth_env.create_user("regadmin4", "adminpw12")
    auth_env.create_user("other", "otherpw123")
    token = auth_env.login("regadmin4", "adminpw12")
    client = auth_env.make_client()
    resp = client.post(
        "/auth/users/other/password",
        json={"password": "Hacked1234!"},
        headers=auth_env.bearer(token),
    )
    assert resp.status_code == 403


def test_admin_can_change_own_password(auth_env):
    auth_env.create_user("selfpw", "oldpass123")
    token = auth_env.login("selfpw", "oldpass123")
    client = auth_env.make_client()
    resp = client.post(
        "/auth/users/selfpw/password",
        json={"password": "NewPass123!"},
        headers=auth_env.bearer(token),
    )
    assert resp.status_code == 200


def test_superadmin_can_change_other_password(auth_env):
    auth_env.create_user("super", "superpw12", role="superadmin")
    auth_env.create_user("target", "targetpw1")
    token = auth_env.login("super", "superpw12")
    client = auth_env.make_client()
    resp = client.post(
        "/auth/users/target/password",
        json={"password": "Changed123!"},
        headers=auth_env.bearer(token),
    )
    assert resp.status_code == 200


def test_superadmin_password_change_revokes_target_sessions(auth_env):
    auth_env.create_user("superrev", "superpw12", role="superadmin")
    auth_env.create_user("victim", "victimpw1")
    victim_token = auth_env.login("victim", "victimpw1")
    super_token = auth_env.login("superrev", "superpw12")
    client = auth_env.make_client()

    resp = client.get("/auth/me", headers=auth_env.bearer(victim_token))
    assert resp.status_code == 200

    resp = client.post(
        "/auth/users/victim/password",
        json={"password": "Changed123!"},
        headers=auth_env.bearer(super_token),
    )
    assert resp.status_code == 200

    # The old session died with the old password.
    resp = client.get("/auth/me", headers=auth_env.bearer(victim_token))
    assert resp.status_code == 401
    assert resp.json()["error_code"] == "SESSION_REVOKED"


def test_superadmin_cannot_delete_self(auth_env):
    auth_env.create_user("superself", "superpw12", role="superadmin")
    token = auth_env.login("superself", "superpw12")
    client = auth_env.make_client()
    resp = client.delete("/auth/users/superself", headers=auth_env.bearer(token))
    assert resp.status_code == 400


def test_admin_cannot_disable_other_totp(auth_env):
    auth_env.create_user("admtotp", "adminpw12")
    auth_env.create_user("totptarget", "targetpw1")
    target_token = auth_env.login("totptarget", "targetpw1")
    auth_env.enable_totp("totptarget", "targetpw1", target_token)
    admin_token = auth_env.login("admtotp", "adminpw12")
    client = auth_env.make_client()
    resp = client.post(
        "/auth/totp/disable",
        json={"password": "adminpw12", "username": "totptarget"},
        headers=auth_env.bearer(admin_token),
    )
    assert resp.status_code == 403


def test_superadmin_can_disable_other_totp(auth_env):
    auth_env.create_user("suptotp", "superpw12", role="superadmin")
    auth_env.create_user("totpvic", "victimpw1")
    vic_token = auth_env.login("totpvic", "victimpw1")
    auth_env.enable_totp("totpvic", "victimpw1", vic_token)
    sup_token = auth_env.login("suptotp", "superpw12")
    client = auth_env.make_client()
    resp = client.post(
        "/auth/totp/disable",
        json={"password": "superpw12", "username": "totpvic"},
        headers=auth_env.bearer(sup_token),
    )
    assert resp.status_code == 200
    resp = client.get("/auth/me", headers=auth_env.bearer(vic_token))
    assert resp.json()["data"]["totp_enabled"] is False


def test_login_returns_role_in_token(auth_env):
    auth_env.create_user("rolecheck", "rolepw123", role="superadmin")
    token = auth_env.login("rolecheck", "rolepw123")
    client = auth_env.make_client()
    resp = client.get("/auth/me", headers=auth_env.bearer(token))
    assert resp.json()["data"]["role"] == "superadmin"


def test_admin_role_in_me(auth_env):
    auth_env.create_user("adminrole", "adminpw12")
    token = auth_env.login("adminrole", "adminpw12")
    client = auth_env.make_client()
    resp = client.get("/auth/me", headers=auth_env.bearer(token))
    assert resp.json()["data"]["role"] == "admin"
