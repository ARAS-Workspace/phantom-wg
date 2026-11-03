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

Contract tests against the built library: its exports, the ctypes
signatures in _ffi.py and the prototypes cgo generated name the same
functions with the same arity; the error codes of the header are the
ones the Python map knows; and a call records its error for the calling
thread. Needs WIREGUARD_GO_BRIDGE_LIB_PATH and, next to the library,
include/ with the header and the cgo prototypes (tests/Dockerfile puts
them there).
"""

import contextlib
import os
import re
import sqlite3
import struct
import threading
import types

import pytest

from wireguard_go_bridge import WireGuardBridge
from wireguard_go_bridge._ffi import _read_and_free, _setup_signatures, get_lib, last_error
from wireguard_go_bridge.keys import derive_public_key
from wireguard_go_bridge.types import (
    DeviceCreateError,
    InvalidArgumentError,
    TunCreateError,
    _ERROR_MAP,
)

LIB_PATH = os.environ.get("WIREGUARD_GO_BRIDGE_LIB_PATH", "")
INCLUDE = os.path.join(os.path.dirname(LIB_PATH), "include")


def exported_functions(path: str) -> set[str]:
    """The defined global and weak functions of an ELF64 little-endian
    library's dynamic symbol table."""
    with open(path, "rb") as f:
        data = f.read()
    assert data[:4] == b"\x7fELF" and data[4] == 2 and data[5] == 1, "not ELF64 LE"
    shoff, = struct.unpack_from("<Q", data, 0x28)
    shentsize, shnum = struct.unpack_from("<HH", data, 0x3A)
    sections = [struct.unpack_from("<IIQQQQIIQQ", data, shoff + i * shentsize)
                for i in range(shnum)]
    dynsym = next(s for s in sections if s[1] == 11)  # SHT_DYNSYM
    strtab_offset = sections[dynsym[6]][4]
    names = set()
    for off in range(dynsym[4], dynsym[4] + dynsym[5], dynsym[9]):
        st_name, st_info, _, st_shndx, _, _ = struct.unpack_from("<IBBHQQ", data, off)
        bind, kind = st_info >> 4, st_info & 0xF
        if st_shndx != 0 and kind == 2 and bind in (1, 2):  # FUNC, GLOBAL or WEAK
            end = data.index(b"\0", strtab_offset + st_name)
            names.add(data[strtab_offset + st_name:end].decode())
    return names


def ctypes_signatures() -> dict[str, types.SimpleNamespace]:
    """The functions _setup_signatures declares, with their argtypes."""
    declared: dict[str, types.SimpleNamespace] = {}

    class Recorder:
        def __getattr__(self, name):
            return declared.setdefault(name, types.SimpleNamespace())

    _setup_signatures(Recorder())
    return declared


def header_prototypes() -> dict[str, int]:
    """Each function cgo generated a prototype for, with its arity."""
    with open(os.path.join(INCLUDE, "exports.h")) as f:
        text = f.read()
    arity = {}
    for name, params in re.findall(r"^extern .*?\b(\w+)\(([^)]*)\);$", text, re.M):
        if not name.startswith("_"):
            arity[name] = 0 if params.strip() in ("", "void") else params.count(",") + 1
    return arity


def header_codes() -> dict[str, int]:
    with open(os.path.join(INCLUDE, "wireguard_go_bridge.h")) as f:
        return {name: int(value) for name, value in
                re.findall(r"^#define\s+(WG_\w+)\s+(-?\d+)\s*$", f.read(), re.M)}


def test_exports_signatures_and_prototypes_name_the_same_functions():
    exports = exported_functions(LIB_PATH)
    assert exports == set(ctypes_signatures()), "exports against _ffi.py"
    assert exports == set(header_prototypes()), "exports against the cgo prototypes"


def test_signatures_have_the_arity_of_the_prototypes():
    prototypes = header_prototypes()
    for name, signature in ctypes_signatures().items():
        assert len(signature.argtypes) == prototypes[name], name


def test_error_codes_are_the_ones_python_maps():
    codes = header_codes()
    assert codes.pop("WG_OK") == 0
    assert set(codes.values()) == set(_ERROR_MAP)


def test_a_failed_call_records_its_code_and_message():
    lib = get_lib()
    assert not lib.DeviceIpcGet(999999)
    assert last_error(lib) == (-5, "device handle 999999 not found")


def test_a_call_that_succeeds_clears_the_record():
    lib = get_lib()
    assert lib.DeviceIpcSet(999999, b"") == -5
    assert _read_and_free(lib.GeneratePrivateKey())
    assert last_error(lib) == (0, "")


def test_each_thread_reads_the_record_of_its_own_call():
    # One thread fails, another then succeeds; the first still reads
    # its own failure.
    lib = get_lib()
    failed, succeeded = threading.Event(), threading.Event()
    seen = []

    def first():
        lib.DeviceIpcGet(999999)
        failed.set()
        seen.append(("second succeeded", succeeded.wait(5)))
        seen.append(last_error(lib))

    def second():
        seen.append(("first failed", failed.wait(5)))
        _read_and_free(lib.GeneratePrivateKey())
        succeeded.set()

    threads = [threading.Thread(target=first), threading.Thread(target=second)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(10)
    assert not any(t.is_alive() for t in threads)
    assert seen == [
        ("first failed", True),
        ("second succeeded", True),
        (-5, "device handle 999999 not found"),
    ]


def test_a_tun_failure_is_tun_create(tmp_path):
    db = tmp_path / "device.db"
    with contextlib.closing(sqlite3.connect(db)) as con:
        con.execute("CREATE TABLE ipc_state (id INTEGER PRIMARY KEY CHECK (id = 1), dump TEXT NOT NULL)")
        con.commit()
    # Longer than the 15 characters of an interface name.
    with pytest.raises(DeviceCreateError) as exc:
        WireGuardBridge(ifname="x" * 20, mtu=1420, db_path=str(db))
    assert type(exc.value) is TunCreateError
    assert exc.value.code == -2
    assert str(exc.value).startswith("create tun: ")


def test_a_refused_key_is_an_invalid_argument():
    with pytest.raises(InvalidArgumentError) as exc:
        derive_public_key("zz")
    assert isinstance(exc.value, ValueError)
    assert exc.value.code == -10
    assert str(exc.value) == "Failed to derive public key: invalid private key hex"
