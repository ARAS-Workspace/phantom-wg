"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.

Shared helpers for the chaos E2E scenarios.

Display, client-tunnel and API-poll helpers used by both
test_daemon_restart and test_ungraceful_shutdown. Fixtures live in
conftest.py; these are plain functions the tests import by name.
"""

from __future__ import annotations

import base64
import functools
import time
from concurrent.futures import ThreadPoolExecutor

import requests

# Force line-by-line flush so output streams live under pytest -s
# noinspection PyShadowingBuiltins
print = functools.partial(print, flush=True)


# ── Display ──────────────────────────────────────────────────────

_SEP = "=" * 64
_THIN = "-" * 64


def _phase(title: str) -> None:
    print(f"\n{_SEP}")
    print(f"  {title}")
    print(f"{_SEP}")


def _info(label: str, value: str) -> None:
    print(f"  {label:24s}: {value}")


def _elapsed(t0: float) -> None:
    print(f"  {'elapsed':24s}: {time.perf_counter() - t0:.2f}s")
    print(f"{_THIN}")


def _api(method: str, path: str, resp: requests.Response) -> None:
    print(f"  {method:4s} {path:44s} -> {resp.status_code}")


def _exec_log(label: str, rc: int, out: str) -> None:
    status = "OK" if rc == 0 else f"FAIL (rc={rc})"
    print(f"  {label:24s}: {status}")
    if out.strip():
        for line in out.strip().splitlines():
            print(f"    | {line}")


# ── Client config adaptation ─────────────────────────────────────

def _adapt_config(raw: str, endpoint_override: str | None = None) -> str:
    """Adapt a wg-quick config for the E2E client, dual-stack aware.

    Widens the host addresses to their subnets (/32->/24, /128->/64) so the
    client can reach its peers, and narrows AllowedIPs from a full tunnel to
    the ULA/private ranges the topology actually uses — 10.0.0.0/8 for v4,
    fd00::/8 for v6 (covers both the daemon's fd00:70:68:: and the exit's
    fd10:0:2::). DNS lines are dropped; there is no resolver in the netns.
    """
    adapted = []
    for line in raw.splitlines():
        stripped = line.strip()
        if stripped.startswith("DNS"):
            continue
        if stripped.startswith("Address"):
            line = line.replace("/32", "/24").replace("/128", "/64")
        if stripped.startswith("AllowedIPs"):
            line = line.replace("0.0.0.0/0", "10.0.0.0/8").replace("::/0", "fd00::/8")
        if endpoint_override and stripped.startswith("Endpoint"):
            line = f"Endpoint = {endpoint_override}"
        adapted.append(line)
    return "\n".join(adapted)


def _gateway_ip_from_conf(conf: str) -> str:
    """Extract gateway IP (x.x.x.1) from client config Address field."""
    for line in conf.splitlines():
        if line.strip().startswith("Address"):
            addr = line.split("=", 1)[1].strip().split("/")[0].split(",")[0].strip()
            return f"{addr.rsplit('.', 1)[0]}.1"
    raise ValueError("No Address in config")


# ── State printers ───────────────────────────────────────────────

def _print_server_state(
    multihop: dict | None = None,
    fw_groups: list[str] | None = None,
) -> None:
    print(f"\n{_THIN}")
    print("  Server State")
    print(f"{_THIN}")
    if multihop is not None:
        active = multihop.get("active", "")
        endpoint = ""
        if multihop.get("exit"):
            endpoint = multihop["exit"].get("endpoint", "")
        _info("multihop", f"{'ENABLED' if multihop['enabled'] else 'disabled'}"
              + (f"  exit={active}  endpoint={endpoint}" if active else ""))
    if fw_groups is not None:
        _info("firewall groups", ", ".join(fw_groups))


def _print_wg_show(container_exec, label: str = "Client WireGuard") -> None:
    print(f"\n{_THIN}")
    print(f"  {label}")
    print(f"{_THIN}")
    rc, out = container_exec("client", "wg show wg0", check=False)
    _exec_log("wg show wg0", rc, out)


def _print_connectivity(container_exec, targets: list[tuple[str, str, bool]]) -> None:
    """Ping each target. A colon in the address selects ping6."""
    print(f"\n{_THIN}")
    print("  Connectivity")
    print(f"{_THIN}")
    for ip, label, should_succeed in targets:
        ping = "ping6" if ":" in ip else "ping"
        rc, out = container_exec("client", f"{ping} -c 3 -W 2 {ip}", check=False)
        ok = rc == 0
        icon = "OK" if ok else "UNREACHABLE"
        print(f"  {label:24s}: {icon} ({ip})")
        if should_succeed:
            assert ok, f"{label} failed: {ip}\n{out}"
        else:
            assert not ok, f"{label} should be unreachable: {ip}"


# ── API polling ──────────────────────────────────────────────────

def _get_server_state(api):
    """Fetch multihop and firewall state via the api fixture."""
    mh = api.get("/api/multihop/status").json()["data"]
    resp = api.get("/api/core/firewall/groups/list")
    groups = resp.json()["data"]
    names = [g["name"] for g in groups] if isinstance(groups, list) else list(groups.keys())
    return mh, names


def _health_check(
    gateway_url: str,
    expected_client: str | None = None,
    expected_exit: str | None = None,
) -> list[tuple[str, bool, str]]:
    """Full health check against the daemon API.

    Returns (check_name, passed, detail) tuples.
    """
    checks: list[tuple[str, bool, str]] = []

    try:
        resp = requests.get(f"{gateway_url}/api/core/hello", timeout=5)
        ok = resp.status_code == 200
        version = resp.json().get("data", {}).get("version", "?") if ok else "?"
        checks.append(("daemon", ok, f"v{version}" if ok else f"HTTP {resp.status_code}"))
    except Exception as exc:
        checks.append(("daemon", False, str(exc)[:60]))
        return checks  # no point continuing

    try:
        resp = requests.get(f"{gateway_url}/api/core/firewall/groups/list", timeout=5)
        ok = resp.status_code == 200
        groups = resp.json()["data"] if ok else []
        names = [g["name"] for g in groups] if isinstance(groups, list) else list(groups.keys())
        checks.append(("firewall", ok, f"{len(names)} groups"))
    except Exception as exc:
        checks.append(("firewall", False, str(exc)[:60]))

    if expected_exit:
        try:
            resp = requests.get(f"{gateway_url}/api/multihop/status", timeout=5)
            ok = resp.status_code == 200
            if ok:
                data = resp.json()["data"]
                enabled = data.get("enabled", False)
                active = data.get("active", "")
                state_ok = enabled and active == expected_exit
                checks.append(("multihop", state_ok, f"enabled={enabled} active={active}"))
            else:
                checks.append(("multihop", False, f"HTTP {resp.status_code}"))
        except Exception as exc:
            checks.append(("multihop", False, str(exc)[:60]))

    if expected_client:
        try:
            resp = requests.get(f"{gateway_url}/api/core/clients/list?limit=100", timeout=5)
            ok = resp.status_code == 200
            if ok:
                names = [c["name"] for c in resp.json()["data"]["clients"]]
                total = resp.json()["data"]["total"]
                checks.append(("client", expected_client in names,
                               f"total={total} found={expected_client in names}"))
            else:
                checks.append(("client", False, f"HTTP {resp.status_code}"))
        except Exception as exc:
            checks.append(("client", False, str(exc)[:60]))

    try:
        resp = requests.get(f"{gateway_url}/api/core/network", timeout=5)
        ok = resp.status_code == 200
        if ok:
            pool = resp.json()["data"]["pool"]
            arithmetic_ok = pool["assigned"] + pool["free"] == pool["total"]
            checks.append(("pool", arithmetic_ok,
                           f"assigned={pool['assigned']} free={pool['free']} "
                           f"total={pool['total']}"))
        else:
            checks.append(("pool", False, f"HTTP {resp.status_code}"))
    except Exception as exc:
        checks.append(("pool", False, str(exc)[:60]))

    return checks


def _print_health_check(round_num: int, checks: list[tuple[str, bool, str]]) -> None:
    print(f"  Health Check (round {round_num}):")
    for name, passed, detail in checks:
        icon = "OK" if passed else "FAIL"
        print(f"    {name:16s}: {icon:4s}  {detail}")


# ── Client tunnel ────────────────────────────────────────────────

def _setup_client_wg(
    api, container_exec, container_write_file,
    name="kill-client", version="v4", endpoint_override=None,
):
    """Fetch a client's config, adapt it, and bring the tunnel up.

    Callers pass name/version explicitly; version='hybrid' drives a
    dual-stack tunnel. Returns the adapted config.
    """
    resp = api.post("/api/core/clients/config", body={"name": name, "version": version})
    assert resp.status_code == 200
    raw = base64.b64decode(resp.json()["data"]).decode()
    conf = _adapt_config(raw, endpoint_override=endpoint_override)
    container_write_file("client", "/etc/wireguard/wg0.conf", conf)
    container_exec("client", "wg-quick down wg0 2>/dev/null || true", check=False)
    container_exec("client", "wg-quick up wg0")
    time.sleep(5)
    return conf


def _teardown_client(container_exec) -> None:
    container_exec("client", "wg-quick down wg0 2>/dev/null || true", check=False)


# ── Bulk client operations (production-scale fill/drain) ──────────

def _bulk_assign(gateway_url: str, names: list[str], workers: int = 10) -> int:
    """Assign clients concurrently. Returns the count committed (201)."""
    def _one(name: str) -> bool:
        try:
            r = requests.post(
                f"{gateway_url}/api/core/clients/assign",
                json={"name": name}, timeout=15,
            )
            return r.status_code == 201
        except (requests.ConnectionError, requests.Timeout):
            return False

    with ThreadPoolExecutor(max_workers=workers) as pool:
        return sum(pool.map(_one, names))


def _bulk_revoke(gateway_url: str, names: list[str], workers: int = 10) -> int:
    """Revoke clients concurrently, tolerating already-absent ones."""
    def _one(name: str) -> bool:
        try:
            r = requests.post(
                f"{gateway_url}/api/core/clients/revoke",
                json={"name": name}, timeout=15,
            )
            return r.status_code == 200
        except (requests.ConnectionError, requests.Timeout):
            return False

    with ThreadPoolExecutor(max_workers=workers) as pool:
        return sum(pool.map(_one, names))


def _all_client_names(gateway_url: str) -> list[str]:
    """Every current client name — used to reset a dirty pool.

    The list endpoint caps limit at 100, so page through until a short
    page ends it.
    """
    names: list[str] = []
    page = 1
    while True:
        resp = requests.get(
            f"{gateway_url}/api/core/clients/list?page={page}&limit=100",
            timeout=15,
        )
        resp.raise_for_status()
        batch = [c["name"] for c in resp.json()["data"]["clients"]]
        names.extend(batch)
        if len(batch) < 100:
            return names
        page += 1
