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

Firewall service lifecycle — bridge wrapper, preset management.
"""

from __future__ import annotations

import copy
import importlib.resources
import logging
import re
from pathlib import Path
from typing import Optional, Type

import yaml
from firewall_bridge import FirewallBridge, FirewallRule, Group, RoutingRule
from firewall_bridge.presets import apply_preset, disable_preset, enable_preset, remove_preset

from phantom_daemon.base.env import DaemonEnv
from phantom_daemon.base.errors import FirewallError
from phantom_daemon.base.services.wireguard import WG_INTERFACE_NAME, WG_INTERFACE_NAME_EXIT
from phantom_daemon.base.wallet.wallet import Wallet

log = logging.getLogger("phantom-daemon")

CORE_PRESET_NAME = "core"
MULTIHOP_PRESET_NAME = "multihop-exit"


# ── Pure Functions ────────────────────────────────────────────────

_TEMPLATE_EXACT = re.compile(r"^\{(\w+)}$")


# noinspection DuplicatedCode
def _resolve_templates(spec: dict, context: dict) -> dict:
    """Walk preset rules and table entries, replace {key} templates with context values."""
    result = copy.deepcopy(spec)
    for rule in result.get("rules", []):
        for key, val in list(rule.items()):
            if not isinstance(val, str):
                continue
            m = _TEMPLATE_EXACT.match(val)
            if m and m.group(1) in context:
                rule[key] = context[m.group(1)]
            elif "{" in val:
                rule[key] = val.format_map(context)
    for entry in result.get("table", []):
        for _action, inner in list(entry.items()):
            if not isinstance(inner, dict):
                continue
            for key, val in list(inner.items()):
                if not isinstance(val, str):
                    continue
                m = _TEMPLATE_EXACT.match(val)
                if m and m.group(1) in context:
                    inner[key] = context[m.group(1)]
                elif "{" in val:
                    inner[key] = val.format_map(context)
    return result


def _read_core_preset() -> dict:
    """Read core.yaml from package resources."""
    ref = importlib.resources.files(
        "phantom_daemon.base.services.firewall.presets"
    ).joinpath("core.yaml")
    return yaml.safe_load(ref.read_text(encoding="utf-8"))


def _resolve_core_preset(env: DaemonEnv, wallet: Wallet) -> dict:
    """Load core preset YAML and resolve {template} placeholders."""
    spec = _read_core_preset()
    context = {
        "listen_port": env.listen_port,
        "wg_interface": WG_INTERFACE_NAME,
        "ipv4_subnet": wallet.get_config("ipv4_subnet") or "",
    }
    return _resolve_templates(spec, context)


def _read_multihop_preset() -> dict:
    """Read multihop.yaml from package resources."""
    ref = importlib.resources.files(
        "phantom_daemon.base.services.firewall.presets"
    ).joinpath("multihop.yaml")
    return yaml.safe_load(ref.read_text(encoding="utf-8"))



def resolve_multihop_preset(
    ipv4_subnet: str,
    wg_interface: str = WG_INTERFACE_NAME,
    wg_interface_exit: str = WG_INTERFACE_NAME_EXIT,
) -> dict:
    """Load multihop preset YAML and resolve {template} placeholders."""
    spec = _read_multihop_preset()
    context = {
        "ipv4_subnet": ipv4_subnet,
        "wg_interface": wg_interface,
        "wg_interface_exit": wg_interface_exit,
    }
    return _resolve_templates(spec, context)


# ── Service ──────────────────────────────────────────────────────


class FirewallService:
    """Firewall bridge lifecycle and preset management."""

    __slots__ = ("_bridge", "_db_path")

    def __init__(self, bridge: FirewallBridge, db_path: Path) -> None:
        self._bridge = bridge
        self._db_path = db_path

    # ── Lifecycle ────────────────────────────────────────────────

    def bootstrap(self, env: DaemonEnv, wallet: Wallet) -> None:
        """First-run initialisation: resolve and apply core preset."""
        spec = _resolve_core_preset(env, wallet)
        apply_preset(self._bridge, spec)
        log.info("firewall: core preset applied")

    def start(self) -> None:
        """Activate firewall — apply all enabled groups to kernel."""
        self._bridge.start()
        log.info("firewall: started")

    def stop(self) -> None:
        """Deactivate firewall — flush rules from kernel."""
        self._bridge.stop()
        log.info("firewall: stopped")

    def close(self) -> None:
        """Close the bridge and release resources."""
        self._bridge.close()

    def get_state(self) -> str:
        """Return bridge state: 'started' or 'stopped'."""
        return self._bridge.get_state()

    # ── Preset Operations ────────────────────────────────────────

    def apply_preset(self, preset: str | Path | dict, **override: object) -> Group:
        """Apply a preset (YAML str, Path, or dict) to the bridge."""
        return apply_preset(self._bridge, preset, **override)

    def remove_preset(self, name: str) -> None:
        """Remove a preset group by name."""
        remove_preset(self._bridge, name)

    def enable_preset(self, name: str) -> None:
        """Enable a preset group by name."""
        enable_preset(self._bridge, name)

    def disable_preset(self, name: str) -> None:
        """Disable a preset group by name."""
        disable_preset(self._bridge, name)

    # ── Read Operations ──────────────────────────────────────────

    def list_groups(self) -> list[Group]:
        """List all firewall groups."""
        return self._bridge.list_groups()

    def get_group(self, name: str) -> Group:
        """Get a single group by name."""
        return self._bridge.get_group(name)

    def list_firewall_rules(
        self, group_name: Optional[str] = None,
    ) -> list[FirewallRule]:
        """List firewall rules, optionally filtered by group."""
        return self._bridge.list_firewall_rules(group_name)

    def list_routing_rules(
        self, group_name: Optional[str] = None,
    ) -> list[RoutingRule]:
        """List routing rules, optionally filtered by group."""
        return self._bridge.list_routing_rules(group_name)

    def list_table(self) -> str:
        """Return current nftables table as JSON string."""
        return self._bridge.list_table()

    # ── Context Manager ──────────────────────────────────────────

    def __enter__(self) -> FirewallService:
        return self

    def __exit__(
        self,
        exc_type: Optional[Type[BaseException]],
        exc_val: Optional[BaseException],
        exc_tb: Optional[object],
    ) -> None:
        self.close()


# ── Factory ──────────────────────────────────────────────────────


def open_firewall(state_dir: str) -> FirewallService:
    """Instantiate firewall bridge with its own DB, return service."""
    dir_path = Path(state_dir)
    if not dir_path.is_dir():
        raise FirewallError(f"State directory does not exist: {state_dir}")

    db_path = dir_path / "firewall.db"

    try:
        bridge = FirewallBridge(db_path=str(db_path))
    except Exception as exc:
        raise FirewallError(
            f"Failed to create firewall bridge: {exc}"
        ) from exc

    return FirewallService(bridge=bridge, db_path=db_path)
