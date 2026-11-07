"""Integration test: full wallet lifecycle — expansion, shrink, and reset to zero.

Run with -s to see live output:
    pytest tests/unit/test_integrity.py -s
"""

from __future__ import annotations

import functools
import ipaddress
import os
import time
from datetime import UTC, datetime

import pytest
from wireguard_go_bridge.keys import derive_public_key

from phantom_daemon.base.errors import WalletFullError
from phantom_daemon.base.wallet import create_wallet, open_wallet

# Force line-by-line flush so output streams live under pytest -s
# noinspection PyShadowingBuiltins
print = functools.partial(print, flush=True)


# ── Helpers ───────────────────────────────────────────────────────

def _db_size(db_dir: str, db_name: str = "wallet.db") -> tuple[float, str]:
    """Return (bytes, human-readable) DB file size."""
    path = os.path.join(db_dir, db_name)
    size = os.path.getsize(path) if os.path.exists(path) else 0
    if size < 1024:
        return size, f"{size} B"
    if size < 1024 * 1024:
        return size, f"{size / 1024:.1f} KB"
    return size, f"{size / (1024 * 1024):.2f} MB"


def _fill(wallet, prefix: str, count: int, log_every: int = 2000) -> float:
    """Assign `count` clients, return elapsed seconds."""
    t0 = time.perf_counter()
    for i in range(count):
        wallet.assign_client(f"{prefix}-{i:05d}")
        done = i + 1
        if done % log_every == 0 or done == count:
            elapsed = time.perf_counter() - t0
            rate = done / elapsed if elapsed > 0 else 0
            print(f"       [{prefix}] {done:>6}/{count}  ({rate:,.0f} client/s)")
    return time.perf_counter() - t0


def _drain(wallet, target: int, log_every: int = 2000) -> float:
    """Revoke clients from the end until count_assigned() == target."""
    clients = wallet.list_clients()
    to_revoke = len(clients) - target
    if to_revoke <= 0:
        return 0.0
    revoke_names = [c["name"] for c in clients[-to_revoke:]]
    t0 = time.perf_counter()
    for i, name in enumerate(revoke_names):
        wallet.revoke_client(name)
        done = i + 1
        if done % log_every == 0 or done == to_revoke:
            elapsed = time.perf_counter() - t0
            rate = done / elapsed if elapsed > 0 else 0
            print(f"       [revoke] {done:>6}/{to_revoke}  ({rate:,.0f} revoke/s)")
    return time.perf_counter() - t0


def _validate_keys(wallet, label: str) -> None:
    """Read all clients from DB, verify Curve25519 derivation + uniqueness."""
    t0 = time.perf_counter()
    clients = wallet.list_clients()
    seen_ids: set[str] = set()
    for c in clients:
        priv = c["private_key_hex"]
        pub = c["public_key_hex"]
        psk = c["preshared_key_hex"]
        name = c["name"]

        # 64-char hex (32 bytes)
        assert len(priv) == 64, f"{name}: private_key len={len(priv)}"
        assert len(pub) == 64, f"{name}: public_key len={len(pub)}"
        assert len(psk) == 64, f"{name}: preshared_key len={len(psk)}"

        # Curve25519: pub == derive(priv)
        derived = derive_public_key(priv)
        assert pub == derived, (
            f"{name}: public key mismatch\n"
            f"  stored  = {pub}\n"
            f"  derived = {derived}"
        )

        # No key collisions (priv, pub, psk all distinct)
        assert len({priv, pub, psk}) == 3, f"{name}: key collision"

        # Unique client IDs
        assert c["id"] not in seen_ids, f"{name}: duplicate id"
        seen_ids.add(c["id"])

    elapsed = time.perf_counter() - t0
    print(f"  Curve25519    : {len(clients):,} keys verified — pub==derive(priv) [{label}]  ({elapsed:.2f}s)")


def _bar(pct: float, width: int = 30) -> str:
    """ASCII progress bar."""
    filled = int(width * pct / 100)
    return f"[{'#' * filled}{'.' * (width - filled)}] {pct:.1f}%"


_SEP = "=" * 64
_THIN = "-" * 64

_DB_DIR = "/var/lib/phantom/db/tests"


# ── Fixture ──────────────────────────────────────────────────────

@pytest.fixture(scope="class")
def shared_db():
    """Shared DB directory for integrity tests within the class."""
    os.makedirs(_DB_DIR, exist_ok=True)
    ts = datetime.now(UTC).strftime("%Y%m%dT%H%M%S")
    return _DB_DIR, f"integrity-{ts}.db"


# ── Test ─────────────────────────────────────────────────────────

@pytest.mark.slow
class TestIntegrity:

    @pytest.mark.integration
    @pytest.mark.dependency()
    def test_progressive_expansion_to_slash16(self, shared_db):
        """Fill -> exhaust -> key validate -> expand, repeated from /24 up to /16."""

        db_dir, db_name = shared_db
        stages = [
            # (cidr_prefix, label)
            (24, "/24"),
            (22, "/22"),
            (20, "/20"),
            (18, "/18"),
            (16, "/16"),
        ]

        db_path = os.path.join(db_dir, db_name)
        print(f"\n{_SEP}")
        print("  WALLET DATABASE — PROGRESSIVE EXPANSION TEST")
        print("  /24 -> /22 -> /20 -> /18 -> /16  (Curve25519 keygen)")
        print(f"  DB: {db_path}")
        print(f"{_SEP}")

        with create_wallet(db_dir, db_name) as w:
            cumulative_assigns = 0
            t_total = time.perf_counter()

            for idx, (cidr, label) in enumerate(stages):

                stage_capacity = 2 ** (32 - cidr) - 3
                print(f"\n{_THIN}")
                print(f"  STAGE {idx}  —  {label}  ({stage_capacity:,} clients)")
                print(f"{_THIN}")

                # ── Expand (skip stage 0, that's the initial /24) ────
                if idx > 0:
                    prev_assigned = w.count_assigned()
                    prev_capacity = w.count_users()
                    _, db_human = _db_size(db_dir, db_name)
                    print(f"  Before expand : {prev_assigned:>6} assigned / {prev_capacity:>6} capacity  DB={db_human}")

                    t0 = time.perf_counter()
                    w.change_cidr(cidr)
                    expand_sec = time.perf_counter() - t0

                    new_capacity = w.count_users()
                    new_assigned = w.count_assigned()
                    new_free = w.count_free()
                    _, db_human = _db_size(db_dir, db_name)
                    print(f"  After expand  : {new_assigned:>6} assigned / {new_capacity:>6} capacity  DB={db_human}")
                    print(f"  Expand time   : {expand_sec:.2f}s  (rebuilt {new_capacity} slots, restored {new_assigned} clients)")
                    print(f"  Free slots    : {new_free}")

                    # Pool + key integrity right after expansion
                    t0 = time.perf_counter()
                    errors = w.validate_pool()
                    val_sec = time.perf_counter() - t0
                    assert errors == [], f"Post-expand pool validation failed: {errors}"
                    print(f"  Pool validate : PASS  ({val_sec:.2f}s, {new_capacity} rows)")

                    _validate_keys(w, f"post-expand {label}")
                else:
                    new_capacity = w.count_users()
                    _, db_human = _db_size(db_dir, db_name)
                    print(f"  Initial pool  : {new_capacity} slots  DB={db_human}")

                # ── Fill ─────────────────────────────────────────────
                current_assigned = w.count_assigned()
                to_fill = new_capacity - current_assigned

                print(f"\n  Fill target   : {new_capacity:>6} (100% of {new_capacity})")
                print(f"  Already have  : {current_assigned:>6}")
                print(f"  To assign     : {to_fill:>6}")

                if to_fill > 0:
                    print()
                    fill_sec = _fill(w, f"s{idx}", to_fill)
                    cumulative_assigns += to_fill
                    rate = to_fill / fill_sec if fill_sec > 0 else 0
                    print(f"\n  Fill time     : {fill_sec:.2f}s  ({rate:,.0f} client/s)")

                # ── Post-fill status ─────────────────────────────────
                final_assigned = w.count_assigned()
                final_free = w.count_free()
                usage_pct = final_assigned / new_capacity * 100
                _, db_human = _db_size(db_dir, db_name)

                print(f"\n  Pool status   : {final_assigned:>6} assigned / {final_free:>6} free / {new_capacity:>6} total")
                print(f"  Usage         : {_bar(usage_pct)}")
                print(f"  DB size       : {db_human}")

                # ── Exhaustion ───────────────────────────────────────
                assert final_free == 0, f"Expected 0 free, got {final_free}"
                with pytest.raises(WalletFullError):
                    w.assign_client("overflow-probe")
                print("  Exhaustion    : CONFIRMED (WalletFullError raised)")

                # ── Post-fill validation ─────────────────────────────
                t0 = time.perf_counter()
                errors = w.validate_pool()
                val_sec = time.perf_counter() - t0
                assert errors == [], f"Post-fill pool validation failed: {errors}"
                print(f"  Pool validate : PASS  ({val_sec:.2f}s)")

                _validate_keys(w, f"post-fill {label}")

            # ══════════════════════════════════════════════════════════
            #  FINAL INTEGRITY
            # ══════════════════════════════════════════════════════════

            total_sec = time.perf_counter() - t_total

            print(f"\n{_SEP}")
            print("  FINAL INTEGRITY CHECKS")
            print(f"{_SEP}")

            final_capacity = w.count_users()
            final_assigned = w.count_assigned()
            final_free = w.count_free()
            usage_pct = final_assigned / final_capacity * 100
            db_bytes, db_human = _db_size(db_dir, db_name)

            print(f"  Subnet        : {w.get_config('ipv4_subnet')}  +  {w.get_config('ipv6_subnet')}")
            print(f"  Capacity      : {final_capacity:,}")
            print(f"  Assigned      : {final_assigned:,}")
            print(f"  Free          : {final_free:,}")
            print(f"  Usage         : {_bar(usage_pct)}")
            print(f"  DB file       : {db_human}  ({db_bytes:,} bytes)")

            # Config correctness
            assert w.get_config("ipv4_subnet") == "10.8.0.0/16"
            assert w.get_config("ipv6_subnet") == "fd00:70:68::/112"
            print("  Config        : PASS")

            # Terazi: all IPs in range + v4_index == v6_index
            v4_net = ipaddress.ip_network("10.8.0.0/16", strict=False)
            v6_net = ipaddress.ip_network("fd00:70:68::/112", strict=False)

            t0 = time.perf_counter()
            rows = w._conn.execute(
                "SELECT ipv4_address, ipv6_address FROM users ORDER BY rowid"
            ).fetchall()
            v4_base = int(v4_net.network_address)
            v6_base = int(v6_net.network_address)
            for v4_str, v6_str in rows:
                v4 = ipaddress.ip_address(v4_str)
                v6 = ipaddress.ip_address(v6_str)
                assert v4 in v4_net
                assert v6 in v6_net
                assert int(v4) - v4_base == int(v6) - v6_base
            terazi_sec = time.perf_counter() - t0
            print(f"  Terazi match  : PASS  ({len(rows):,} rows, {terazi_sec:.2f}s)")

            # Spot-check: first client from every stage still alive
            for stage_idx in range(len(stages)):
                name = f"s{stage_idx}-00000"
                client = w.get_client(name)
                assert client is not None, f"Lost client {name}"
                assert client["id"] is not None
            print("  Spot check    : PASS  (first client from each stage verified)")

            # Summary
            print(f"\n{_THIN}")
            print(f"  Total assigns : {cumulative_assigns:,}")
            print(f"  Total time    : {total_sec:.1f}s")
            if total_sec > 0:
                print(f"  Avg rate      : {cumulative_assigns / total_sec:,.0f} client/s (including expansions + key validation)")
            print(f"{_THIN}")
            print("  ALL CHECKS PASSED")
            print(f"  DB preserved  : {db_path}")
            print(f"{_SEP}\n")

    @pytest.mark.integration
    @pytest.mark.dependency(depends=["TestIntegrity::test_progressive_expansion_to_slash16"])
    def test_progressive_shrink_to_zero(self, shared_db):
        """Revoke -> shrink -> key validate, repeated from /16 down to /24, then drain to zero."""

        db_dir, db_name = shared_db
        stages = [
            # (cidr_prefix, label)
            (18, "/18"),
            (20, "/20"),
            (22, "/22"),
            (24, "/24"),
        ]

        db_path = os.path.join(db_dir, db_name)
        print(f"\n{_SEP}")
        print("  WALLET DATABASE — PROGRESSIVE SHRINK TEST")
        print("  /16 -> /18 -> /20 -> /22 -> /24 -> 0  (client revocation)")
        print(f"  DB: {db_path}")
        print(f"{_SEP}")

        with open_wallet(db_dir, db_name) as w:
            cumulative_revokes = 0
            t_total = time.perf_counter()

            for idx, (cidr, label) in enumerate(stages):

                target_capacity = 2 ** (32 - cidr) - 3
                print(f"\n{_THIN}")
                print(f"  STAGE {idx}  —  {label}  ({target_capacity:,} clients)")
                print(f"{_THIN}")

                current_assigned = w.count_assigned()
                current_capacity = w.count_users()
                _, db_human = _db_size(db_dir, db_name)
                print(f"  Before shrink : {current_assigned:>6} assigned / {current_capacity:>6} capacity  DB={db_human}")

                # ── Revoke ──────────────────────────────────────────
                to_revoke = current_assigned - target_capacity
                print(f"  To revoke     : {to_revoke:>6}")

                if to_revoke > 0:
                    print()
                    drain_sec = _drain(w, target_capacity)
                    cumulative_revokes += to_revoke
                    rate = to_revoke / drain_sec if drain_sec > 0 else 0
                    print(f"\n  Revoke time   : {drain_sec:.2f}s  ({rate:,.0f} revoke/s)")

                post_revoke = w.count_assigned()
                print(f"  After revoke  : {post_revoke:>6} assigned")

                # ── Shrink ──────────────────────────────────────────
                t0 = time.perf_counter()
                w.change_cidr(cidr)
                shrink_sec = time.perf_counter() - t0

                new_capacity = w.count_users()
                new_assigned = w.count_assigned()
                new_free = w.count_free()
                _, db_human = _db_size(db_dir, db_name)

                print(f"  After shrink  : {new_assigned:>6} assigned / {new_capacity:>6} capacity  DB={db_human}")
                print(f"  Shrink time   : {shrink_sec:.2f}s  (rebuilt {new_capacity} slots, restored {new_assigned} clients)")
                print(f"  Free slots    : {new_free}")

                # ── Post-shrink status ──────────────────────────────
                usage_pct = new_assigned / new_capacity * 100
                print(f"\n  Pool status   : {new_assigned:>6} assigned / {new_free:>6} free / {new_capacity:>6} total")
                print(f"  Usage         : {_bar(usage_pct)}")
                print(f"  DB size       : {db_human}")

                # ── Exhaustion ──────────────────────────────────────
                assert new_free == 0, f"Expected 0 free, got {new_free}"
                with pytest.raises(WalletFullError):
                    w.assign_client("overflow-probe")
                print("  Exhaustion    : CONFIRMED (WalletFullError raised)")

                # ── Post-shrink validation ──────────────────────────
                t0 = time.perf_counter()
                errors = w.validate_pool()
                val_sec = time.perf_counter() - t0
                assert errors == [], f"Post-shrink pool validation failed: {errors}"
                print(f"  Pool validate : PASS  ({val_sec:.2f}s, {new_capacity} rows)")

                _validate_keys(w, f"post-shrink {label}")

            # ══════════════════════════════════════════════════════════
            #  DRAIN ALL — revoke remaining clients to zero
            # ══════════════════════════════════════════════════════════

            remaining = w.count_assigned()
            print(f"\n{_THIN}")
            print(f"  FINAL DRAIN  —  {remaining:,} clients -> 0")
            print(f"{_THIN}")

            if remaining > 0:
                print()
                drain_sec = _drain(w, 0)
                cumulative_revokes += remaining
                rate = remaining / drain_sec if drain_sec > 0 else 0
                print(f"\n  Drain time    : {drain_sec:.2f}s  ({rate:,.0f} revoke/s)")

            assert w.count_assigned() == 0
            assert w.count_free() == w.count_users()
            assert w.list_clients() == []
            print("  Assigned      : 0")
            print(f"  Free          : {w.count_free()}")
            print("  list_clients  : [] (empty)")

            # Pool still valid after full drain
            t0 = time.perf_counter()
            errors = w.validate_pool()
            val_sec = time.perf_counter() - t0
            assert errors == [], f"Post-drain pool validation failed: {errors}"
            print(f"  Pool validate : PASS  ({val_sec:.2f}s)")

            # ══════════════════════════════════════════════════════════
            #  FINAL INTEGRITY
            # ══════════════════════════════════════════════════════════

            total_sec = time.perf_counter() - t_total

            print(f"\n{_SEP}")
            print("  FINAL INTEGRITY CHECKS")
            print(f"{_SEP}")

            final_capacity = w.count_users()
            final_assigned = w.count_assigned()
            final_free = w.count_free()
            db_bytes, db_human = _db_size(db_dir, db_name)

            print(f"  Subnet        : {w.get_config('ipv4_subnet')}  +  {w.get_config('ipv6_subnet')}")
            print(f"  Capacity      : {final_capacity:,}")
            print(f"  Assigned      : {final_assigned:,}")
            print(f"  Free          : {final_free:,}")
            print(f"  Usage         : {_bar(0.0)}")
            print(f"  DB file       : {db_human}  ({db_bytes:,} bytes)")

            # Config correctness — back to /24
            assert w.get_config("ipv4_subnet") == "10.8.0.0/24"
            assert w.get_config("ipv6_subnet") == "fd00:70:68::/120"
            assert final_assigned == 0
            assert final_free == 253
            print("  Config        : PASS")

            # Terazi: all IPs in range + v4_index == v6_index
            v4_net = ipaddress.ip_network("10.8.0.0/24", strict=False)
            v6_net = ipaddress.ip_network("fd00:70:68::/120", strict=False)

            t0 = time.perf_counter()
            rows = w._conn.execute(
                "SELECT ipv4_address, ipv6_address FROM users ORDER BY rowid"
            ).fetchall()
            v4_base = int(v4_net.network_address)
            v6_base = int(v6_net.network_address)
            for v4_str, v6_str in rows:
                v4 = ipaddress.ip_address(v4_str)
                v6 = ipaddress.ip_address(v6_str)
                assert v4 in v4_net
                assert v6 in v6_net
                assert int(v4) - v4_base == int(v6) - v6_base
            terazi_sec = time.perf_counter() - t0
            print(f"  Terazi match  : PASS  ({len(rows):,} rows, {terazi_sec:.2f}s)")

            # All clients gone
            assert w.get_client("s0-00000") is None
            print("  Client check  : PASS  (all clients revoked, s0-00000 = None)")

            # Summary
            print(f"\n{_THIN}")
            print(f"  Total revokes : {cumulative_revokes:,}")
            print(f"  Total time    : {total_sec:.1f}s")
            if total_sec > 0:
                print(f"  Avg rate      : {cumulative_revokes / total_sec:,.0f} revoke/s (including shrinks + key validation)")
            print(f"{_THIN}")
            print("  ALL CHECKS PASSED — WALLET RESET TO ZERO")
            print(f"  DB preserved  : {db_path}")
            print(f"{_SEP}\n")
