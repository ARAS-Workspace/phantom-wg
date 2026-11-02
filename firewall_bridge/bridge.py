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

FirewallBridge — ufw pattern firewall manager.

Owns: SQLite DB (rules + state), state machine (start/stop).
Delegates: kernel operations to Rust FFI (nftables + netlink).
Knows nothing about: WireGuard, VPN, ghost mode, or any domain.
"""

from __future__ import annotations

from types import TracebackType
from typing import Optional, Type

import ctypes

from ._ffi import NftRule, get_lib, _read_and_free
from .db import FirewallDB
from .models import Group, FirewallRule, RoutingRule
from .schema import validate_firewall_rule
from .types import (
    AlreadyStartedError,
    NotStartedError,
    check_result,
)


def _encode(s: str) -> bytes:
    return s.encode("utf-8")


class FirewallBridge:
    """Generic firewall manager — ufw pattern with SQLite persistence.

    Owns: DB (rules + state), state machine (start/stop).
    Delegates: kernel operations to Rust FFI.
    """

    __slots__ = ("_db", "_lib")

    def __init__(self, db_path: str) -> None:
        self._db = FirewallDB(db_path)
        self._lib = get_lib()
        self._db.clear_applied_state()
        self._db.set_state("stopped")
        rc = self._lib.nft_init()
        check_result(rc)

    # ---- Lifecycle ----

    def start(self) -> None:
        """Write the table, then apply all enabled rules from DB to kernel:
        the firewall rules with _rebuild_fw, then the routing rules.

        If the kernel refuses a rule, what was applied is removed again,
        the bridge is left stopped and the error is raised.
        """
        state = self._db.get_state()
        if state == "started":
            raise AlreadyStartedError("Bridge already started")
        check_result(self._lib.nft_init())
        self._flush_stale_routing()
        try:
            self._rebuild_fw()
            for group in self._db.enabled_groups():
                self._apply_routing(group)
        except BaseException:
            self._empty_table()
            self._remove_all_routing()
            self._db.clear_applied_state()
            raise
        self._db.set_state("started")

    def stop(self) -> None:
        """Replace the table with one with no rules, remove the applied
        routing rules from kernel, mark all unapplied."""
        state = self._db.get_state()
        if state != "started":
            raise NotStartedError("Bridge not started")
        self._empty_table()
        self._remove_all_routing()
        self._db.clear_applied_state()
        self._db.set_state("stopped")

    def close(self) -> None:
        """Release resources."""
        self._lib.nft_close()
        self._db.close()

    def get_state(self) -> str:
        return self._db.get_state()

    # ---- Rule Groups ----

    def create_group(self, name: str, group_type: str = "custom",
                     priority: int = 100, metadata: Optional[dict] = None) -> Group:
        return self._db.create_group(name, group_type, priority, metadata)

    def delete_group(self, name: str) -> None:
        """Delete a group. When started, it is withdrawn with _withdraw; when
        stopped, its routing rules are removed from kernel all the same, and
        a refusal is not raised."""
        group = self._db.get_group(name)
        if self._db.get_state() == "started":
            self._withdraw(group)
        else:
            for rule in self._db.routing_rules_for_group(group.id):
                self._kernel_remove_routing(rule)
        self._db.delete_group(name)

    def enable_group(self, name: str) -> None:
        """Enable a group; when started, apply its rules too: the firewall
        rules with _rebuild_fw, then its routing rules. A group that is
        enabled already is left as it is.

        If the kernel refuses one, what was applied is removed again, the
        group is left disabled and the error is raised.
        """
        if self._db.get_group(name).enabled:
            return
        self._db.enable_group(name)
        if self._db.get_state() == "started":
            group = self._db.get_group(name)
            try:
                self._rebuild_fw()
                self._apply_routing(group)
            except BaseException:
                self._unapply_group(group)
                self._db.disable_group(name)
                raise

    def disable_group(self, name: str) -> None:
        if self._db.get_state() == "started":
            self._withdraw(self._db.get_group(name))
        self._db.disable_group(name)

    def list_groups(self) -> list[Group]:
        return self._db.list_groups()

    def get_group(self, name: str) -> Group:
        return self._db.get_group(name)

    # ---- Firewall Rules ----

    def add_firewall_rule(self, group_name: str, chain: str, action: str,
                          family: int = 2, proto: str = "", dport: int = 0,
                          source: str = "", destination: str = "",
                          in_iface: str = "", out_iface: str = "",
                          state_match: str = "", comment: str = "",
                          position: int = 0) -> int:
        """Store a rule; when started and its group enabled, apply it too,
        with _rebuild_fw.

        Fields that fail validate_firewall_rule raise InvalidParamError
        before anything is stored. A rule the kernel refuses is deleted from
        the DB again and the error is raised.
        """
        validate_firewall_rule({
            "chain": chain, "action": action, "family": family, "proto": proto,
            "dport": dport, "source": source, "destination": destination,
            "in_iface": in_iface, "out_iface": out_iface, "state": state_match,
            "comment": comment, "position": position,
        })
        rule_id = self._db.add_firewall_rule(
            group_name, chain, action, family, proto, dport, source,
            destination, in_iface, out_iface, state_match, comment, position,
        )
        if self._db.get_state() == "started" and self._db.is_group_enabled(group_name):
            try:
                self._rebuild_fw()
            except BaseException:
                self._db.remove_firewall_rule(rule_id)
                raise
        return rule_id

    def remove_firewall_rule(self, rule_id: int) -> None:
        """Delete a rule; when it is applied, the table is first rebuilt
        without it with _rebuild_fw. When nft refuses the table, the rule is
        kept and the error is raised."""
        if self._db.get_firewall_rule(rule_id).applied:
            self._rebuild_fw(exclude=rule_id)
        self._db.remove_firewall_rule(rule_id)

    def list_firewall_rules(self, group_name: Optional[str] = None) -> list[FirewallRule]:
        return self._db.list_firewall_rules(group_name)

    # ---- Routing Rules ----

    def add_routing_rule(self, group_name: str, rule_type: str,
                         family: int = 2,
                         from_network: str = "", to_network: str = "",
                         table_name: str = "", table_id: int = 0,
                         priority: int = 0, destination: str = "",
                         device: str = "") -> int:
        """Store a routing rule; when started and its group enabled, apply
        it too.

        A rule the kernel refuses is deleted from the DB again and the
        error is raised.
        """
        rule_id = self._db.add_routing_rule(
            group_name, rule_type, family, from_network, to_network,
            table_name, table_id, priority, destination, device,
        )
        if self._db.get_state() == "started" and self._db.is_group_enabled(group_name):
            try:
                self._kernel_apply_routing(self._db.get_routing_rule(rule_id))
            except BaseException:
                self._db.remove_routing_rule(rule_id)
                raise
            self._db.update_rt_applied(rule_id, True)
        return rule_id

    def remove_routing_rule(self, rule_id: int) -> None:
        """Delete a routing rule; when it is applied, or the bridge is
        stopped, it is removed from kernel too, and a refusal is not
        raised."""
        rule = self._db.remove_routing_rule(rule_id)
        if rule.applied or self._db.get_state() != "started":
            self._kernel_remove_routing(rule)

    def list_routing_rules(self, group_name: Optional[str] = None) -> list[RoutingRule]:
        return self._db.list_routing_rules(group_name)

    # ---- Utility ----

    def enable_ip_forward(self) -> None:
        check_result(self._lib.rt_enable_ip_forward())

    def flush_cache(self) -> None:
        check_result(self._lib.rt_flush_cache())

    def flush_table(self) -> None:
        check_result(self._lib.nft_flush_table())

    def list_table(self) -> str:
        return _read_and_free(self._lib.nft_list_table())

    # ---- Kernel operations (private) ----

    def _rebuild_fw(self, exclude: int = 0) -> None:
        """The table's rules become the enabled groups' rules but the rule
        with id `exclude`, by group priority, then position and id, in one
        nft transaction; the DB gets their handles. When nft refuses one,
        the table and the DB are as they were and the error is raised."""
        rules = [r for g in self._db.enabled_groups()
                 for r in self._db.firewall_rules_for_group(g.id) if r.id != exclude]
        for rule, handle in zip(rules, self._kernel_replace_fw_rules(rules)):
            self._db.update_fw_applied(rule.id, True, handle)

    def _empty_table(self) -> None:
        """The table replaced with one with no rules; a refusal is not
        raised."""
        self._lib.nft_replace_rules(None, 0, None)

    def _kernel_replace_fw_rules(self, rules: list[FirewallRule]) -> list[int]:
        """The table's rules become `rules`, in one transaction; returns
        their handles, in order."""
        array = (NftRule * len(rules))(*(
            NftRule(_encode(r.chain), _encode(r.action), r.family, _encode(r.proto),
                    r.dport, _encode(r.source), _encode(r.destination),
                    _encode(r.in_iface), _encode(r.out_iface),
                    _encode(r.state_match), _encode(r.comment))
            for r in rules
        ))
        handles = (ctypes.c_uint64 * len(rules))()
        check_result(self._lib.nft_replace_rules(array, len(rules), handles))
        return list(handles)

    def _kernel_apply_routing(self, rule: RoutingRule) -> None:
        rt = rule.rule_type
        if rt == "ensure":
            rc = self._lib.rt_table_ensure(
                rule.table_id, _encode(rule.table_name),
            )
            check_result(rc)
        elif rt == "policy":
            rc = self._lib.rt_policy_add(
                _encode(rule.from_network),
                _encode(rule.to_network),
                _encode(self._table_for(rule)),
                rule.priority,
                rule.family,
            )
            check_result(rc)
        elif rt == "route":
            rc = self._lib.rt_route_add(
                _encode(rule.destination),
                _encode(rule.device),
                _encode(self._table_for(rule)),
                rule.family,
            )
            check_result(rc)

    def _kernel_remove_routing(self, rule: RoutingRule) -> None:
        """A route in a table its own group ensures is deleted by destination
        and table, whatever its device; elsewhere by its device too, and a
        route there with no device is not sent."""
        rt = rule.rule_type
        if rt == "policy":
            self._lib.rt_policy_delete(
                _encode(rule.from_network),
                _encode(rule.to_network),
                _encode(self._table_for(rule)),
                rule.priority,
                rule.family,
            )
        elif rt == "route":
            owned = self._db.ensure_table_id(rule.group_id, rule.table_name) is not None
            if not owned and not rule.device:
                return
            self._lib.rt_route_delete(
                _encode(rule.destination),
                _encode("" if owned else rule.device),
                _encode(self._table_for(rule)),
                rule.family,
            )

    def _table_for(self, rule: RoutingRule) -> str:
        """The table a policy or route row is sent to: the id of its own
        group's ensure row for that name, else the name as written."""
        table_id = self._db.ensure_table_id(rule.group_id, rule.table_name)
        return rule.table_name if table_id is None else str(table_id)

    def _apply_routing(self, group: Group) -> None:
        """Apply a group's routing rules to kernel."""
        for rule in self._db.routing_rules_for_group(group.id):
            self._kernel_apply_routing(rule)
            self._db.update_rt_applied(rule.id, True)

    def _unapply_group(self, group: Group) -> None:
        """Remove all applied rules in a group from kernel."""
        for rule in self._db.firewall_rules_for_group(group.id):
            if rule.applied and rule.nft_handle:
                self._lib.nft_remove_rule(
                    _encode(rule.chain), rule.nft_handle,
                )
                self._db.update_fw_applied(rule.id, False, 0)
        self._unapply_routing(group)

    def _withdraw(self, group: Group) -> None:
        """A started bridge's group out of the kernel: when it is enabled
        and has applied firewall rules, the table rebuilt without them with
        _rebuild_fw, then its routing rules removed. When nft refuses the
        table, the group is as it was and the error is raised."""
        if group.enabled and any(r.applied for r in self._db.firewall_rules_for_group(group.id)):
            self._db.disable_group(group.name)
            try:
                self._rebuild_fw()
            except BaseException:
                self._db.enable_group(group.name)
                raise
            for rule in self._db.firewall_rules_for_group(group.id):
                self._db.update_fw_applied(rule.id, False, 0)
        self._unapply_routing(group)

    def _unapply_routing(self, group: Group) -> None:
        for rule in self._db.routing_rules_for_group(group.id):
            if rule.applied:
                self._kernel_remove_routing(rule)
                self._db.update_rt_applied(rule.id, False)

    def _remove_all_routing(self) -> None:
        """Remove all applied routing rules from kernel."""
        for rule in self._db.list_routing_rules():
            if rule.applied:
                self._kernel_remove_routing(rule)

    def _flush_stale_routing(self) -> None:
        """Every routing row of the database, applied or not, removed from
        kernel; a refusal is not raised."""
        for rule in self._db.list_routing_rules():
            self._kernel_remove_routing(rule)

    # ---- Context manager ----

    def __enter__(self) -> FirewallBridge:
        return self

    def __exit__(
        self,
        exc_type: Optional[Type[BaseException]],
        exc_val: Optional[BaseException],
        exc_tb: Optional[TracebackType],
    ) -> None:
        self.close()
