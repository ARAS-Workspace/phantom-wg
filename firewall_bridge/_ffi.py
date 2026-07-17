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

Low-level ctypes bindings to libfirewall_bridge_linux.so — kernel ops only.
Rust side has no DB, no state — pure nftables + netlink operations.
"""

import ctypes
import ctypes.util
import os
import platform
from typing import Optional

_lib: Optional[ctypes.CDLL] = None

c_p = ctypes.c_char_p
c_vp = ctypes.c_void_p
c_i32 = ctypes.c_int32
c_i64 = ctypes.c_int64
c_u32 = ctypes.c_uint32
c_u64 = ctypes.c_uint64


def _resolve_platform():
    machine = platform.machine().lower()
    if machine in ("x86_64", "amd64"):
        arch_dir = "linux-amd64"
    elif machine in ("aarch64", "arm64"):
        arch_dir = "linux-arm64"
    else:
        arch_dir = f"linux-{machine}"
    return "libfirewall_bridge_linux.so", arch_dir


def _find_library() -> str:
    env_path = os.environ.get("FIREWALL_BRIDGE_LIB_PATH")
    if env_path and os.path.isfile(env_path):
        return env_path

    lib_name, _ = _resolve_platform()

    sibling_path = os.path.join(os.path.dirname(__file__), lib_name)
    if os.path.isfile(sibling_path):
        return sibling_path

    found = ctypes.util.find_library("firewall_bridge_linux")
    if found:
        return found

    raise FileNotFoundError(
        f"{lib_name} not found. Set FIREWALL_BRIDGE_LIB_PATH environment variable."
    )


def get_lib() -> ctypes.CDLL:
    global _lib
    if _lib is not None:
        return _lib
    path = _find_library()
    _lib = ctypes.CDLL(path)
    _setup_signatures(_lib)
    return _lib


def _setup_signatures(lib: ctypes.CDLL) -> None:
    """Define C function signatures — kernel ops only."""

    # ---- nftables ----
    lib.nft_init.argtypes = []
    lib.nft_init.restype = c_i32

    lib.nft_close.argtypes = []
    lib.nft_close.restype = None

    lib.nft_add_rule.argtypes = [
        c_p,   # chain
        c_p,   # action
        c_i32, # family
        c_p,   # proto
        c_i32, # dport
        c_p,   # source
        c_p,   # destination
        c_p,   # in_iface
        c_p,   # out_iface
        c_p,   # state_match
        c_p,   # comment
    ]
    lib.nft_add_rule.restype = c_i64

    lib.nft_remove_rule.argtypes = [c_p, c_u64]  # chain, handle
    lib.nft_remove_rule.restype = c_i32

    lib.nft_flush_table.argtypes = []
    lib.nft_flush_table.restype = c_i32

    lib.nft_list_table.argtypes = []
    lib.nft_list_table.restype = c_vp  # JSON, caller frees

    # ---- routing ----
    lib.rt_table_ensure.argtypes = [c_u32, c_p]  # table_id, table_name
    lib.rt_table_ensure.restype = c_i32

    lib.rt_policy_add.argtypes = [c_p, c_p, c_p, c_u32, c_i32]  # from, to, table, priority, family
    lib.rt_policy_add.restype = c_i32

    lib.rt_policy_delete.argtypes = [c_p, c_p, c_p, c_u32, c_i32]
    lib.rt_policy_delete.restype = c_i32

    lib.rt_route_add.argtypes = [c_p, c_p, c_p, c_i32]  # dest, device, table, family
    lib.rt_route_add.restype = c_i32

    lib.rt_route_delete.argtypes = [c_p, c_p, c_p, c_i32]
    lib.rt_route_delete.restype = c_i32

    lib.rt_enable_ip_forward.argtypes = []
    lib.rt_enable_ip_forward.restype = c_i32

    lib.rt_flush_cache.argtypes = []
    lib.rt_flush_cache.restype = c_i32

    # ---- utility ----
    lib.firewall_bridge_get_version.argtypes = []
    lib.firewall_bridge_get_version.restype = c_p  # static, no free

    lib.firewall_bridge_get_last_error.argtypes = []
    lib.firewall_bridge_get_last_error.restype = c_p  # deprecated: dangles on next error

    lib.firewall_bridge_get_last_error_copy.argtypes = [ctypes.c_char_p, c_i32]
    lib.firewall_bridge_get_last_error_copy.restype = c_i32

    lib.firewall_bridge_free_string.argtypes = [c_vp]
    lib.firewall_bridge_free_string.restype = None


def _read_and_free(ptr) -> str:
    """Read a Rust-allocated C string and free it."""
    if not ptr:
        return ""
    s = ctypes.cast(ptr, c_p)
    text = s.value.decode("utf-8") if s.value else ""
    get_lib().firewall_bridge_free_string(ptr)
    return text


def get_version() -> str:
    result = get_lib().firewall_bridge_get_version()
    return result.decode("utf-8") if result else "unknown"


def get_last_error() -> str:
    """Read the last error via the copy API.

    The copy happens inside the Rust error lock, so the buffer can
    never dangle — unlike the raw-pointer variant, whose result is
    invalidated by the next recorded error.
    """
    buf = ctypes.create_string_buffer(1024)
    n = get_lib().firewall_bridge_get_last_error_copy(buf, 1024)
    return buf.value.decode("utf-8", errors="replace") if n > 0 else ""
