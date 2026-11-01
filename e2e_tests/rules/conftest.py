"""
Fixtures for the rule stage.

Runs in the bridge container after the topology stage, in the same network
namespace. Each test starts with inet phantom deleted and inet reference
written fresh, and ends with both deleted. The topology stage's interfaces,
ip rules and routes are left as they are.
"""

from __future__ import annotations

import pytest

pytest.register_assert_rewrite("e2e_tests.rules.oracle")

from firewall_bridge import FirewallBridge, get_lib  # noqa: E402

from e2e_tests.rules import oracle  # noqa: E402


@pytest.fixture(scope="session")
def meter():
    """The process meter, made once the library is loaded."""
    get_lib()
    meter = oracle.ProcessMeter()
    yield meter
    print(f"\n  meter: {meter.report()}", flush=True)


@pytest.fixture
def tables():
    oracle.delete_table(oracle.PHANTOM)
    oracle.delete_table(oracle.REFERENCE)
    oracle.create_reference()
    yield
    oracle.delete_table(oracle.PHANTOM)
    oracle.delete_table(oracle.REFERENCE)


@pytest.fixture
def db_path(tmp_path) -> str:
    return str(tmp_path / "firewall.db")


@pytest.fixture
def bridge(tables, meter, db_path):
    """A FirewallBridge on a new database. Closed after the test, then the
    meter's descriptors and threads are checked."""
    b = FirewallBridge(db_path)
    yield b
    b.close()
    meter.check_resources()
