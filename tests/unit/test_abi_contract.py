"""The C header, the Rust exports and the ctypes bindings are one contract.

Nothing enforced it before: ctypes never reads the header, so when v2.1.2
threaded `family` through rt_policy_* and rt_route_*, Rust and _ffi.py were
updated and include/firewall_bridge_linux.h was not. Python kept working and
the header shipped in every release zip declaring the wrong arity — a C
consumer compiling against it would have pushed a garbage register.

These tests are the consumer the header never had.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

# noinspection PyProtectedMember
from firewall_bridge import _ffi

PROJECT_ROOT = Path(__file__).resolve().parents[2]
HEADER = PROJECT_ROOT / "include" / "firewall_bridge_linux.h"
LIB_RS = PROJECT_ROOT / "src" / "lib.rs"
ERROR_RS = PROJECT_ROOT / "src" / "error.rs"

# Declared in the header but deliberately absent from _ffi.py: Python reads
# the version through its own package metadata, not across the FFI.
_PY_EXEMPT: set[str] = set()


def _header_functions() -> dict[str, int]:
    """Map exported name -> parameter count, parsed from the C header."""
    text = HEADER.read_text()
    # Strip comments so a commented-out prototype cannot register.
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)

    out: dict[str, int] = {}
    for m in re.finditer(
        r"^\s*(?:int32_t|int64_t|void|char\*|const char\*)\s+"
        r"(\w+)\s*\(([^;]*?)\)\s*;",
        text,
        flags=re.M | re.S,
    ):
        name, params = m.group(1), m.group(2).strip()
        if params in ("void", ""):
            out[name] = 0
        else:
            out[name] = len([p for p in params.split(",") if p.strip()])
    return out


def _rust_exports() -> dict[str, int]:
    """Map exported name -> parameter count, parsed from src/lib.rs."""
    text = LIB_RS.read_text()
    out: dict[str, int] = {}
    for m in re.finditer(
        r'#\[no_mangle\]\s*pub extern "C" fn\s+(\w+)\s*\((.*?)\)\s*(?:->|\{)',
        text,
        flags=re.S,
    ):
        name, params = m.group(1), m.group(2).strip()
        out[name] = len([p for p in params.split(",") if p.strip()])
    return out


@pytest.fixture(scope="module")
def header() -> dict[str, int]:
    return _header_functions()


@pytest.fixture(scope="module")
def rust() -> dict[str, int]:
    return _rust_exports()


class TestHeaderMatchesRust:
    def test_parsers_found_something(self, header, rust):
        """Guard the guard — a broken regex must not pass silently."""
        assert len(rust) >= 15, f"only parsed {len(rust)} Rust exports"
        assert len(header) >= 15, f"only parsed {len(header)} header decls"

    def test_no_export_missing_from_header(self, header, rust):
        missing = set(rust) - set(header)
        assert not missing, f"exported by Rust, absent from header: {sorted(missing)}"

    def test_no_header_decl_without_export(self, header, rust):
        extra = set(header) - set(rust)
        assert not extra, f"declared in header, not exported by Rust: {sorted(extra)}"

    def test_arity_matches(self, header, rust):
        mismatched = {
            name: (rust[name], header[name])
            for name in rust
            if name in header and rust[name] != header[name]
        }
        assert not mismatched, (
            "arity drift (name: rust vs header): "
            + ", ".join(f"{n}: {r} vs {h}" for n, (r, h) in sorted(mismatched.items()))
        )


class TestPythonMatchesRust:
    """_ffi.py declares argtypes for every symbol it calls — that count is
    the third copy of the same contract."""

    def test_argtypes_arity_matches_rust(self, rust):
        text = (PROJECT_ROOT / "firewall_bridge" / "_ffi.py").read_text()
        declared = {}
        for m in re.finditer(r"lib\.(\w+)\.argtypes\s*=\s*\[([^\]]*)]", text):
            # Each entry is annotated (`c_p,   # chain`); the comments must go
            # before splitting or the last one counts as an extra argument.
            body = re.sub(r"#[^\n]*", "", m.group(2))
            declared[m.group(1)] = len([a for a in body.split(",") if a.strip()])
        assert declared, "no argtypes declarations parsed from _ffi.py"

        mismatched = {
            name: (rust[name], declared[name])
            for name in declared
            if name in rust and rust[name] != declared[name]
        }
        assert not mismatched, (
            "argtypes drift (name: rust vs _ffi.py): "
            + ", ".join(f"{n}: {r} vs {p}" for n, (r, p) in sorted(mismatched.items()))
        )

    def test_every_bound_symbol_exists_in_rust(self, rust):
        text = (PROJECT_ROOT / "firewall_bridge" / "_ffi.py").read_text()
        bound = set(re.findall(r"lib\.(\w+)\.argtypes", text))
        unknown = bound - set(rust) - _PY_EXEMPT
        assert not unknown, f"_ffi.py binds symbols Rust does not export: {sorted(unknown)}"


class TestErrorCodesMatch:
    """Rust enum, C defines and the Python map are three copies of one table."""

    def test_header_defines_match_rust_enum(self):
        rust_codes = {
            int(m.group(2))
            for m in re.finditer(r"(\w+)\s*=\s*(-?\d+),", ERROR_RS.read_text())
        }
        header_codes = {
            int(m.group(1))
            for m in re.finditer(r"#define\s+FW_\w+\s+(-?\d+)", HEADER.read_text())
        }
        assert rust_codes == header_codes, (
            f"rust={sorted(rust_codes)} header={sorted(header_codes)}"
        )

    def test_python_map_matches_rust_enum(self):
        rust_codes = {
            int(m.group(2))
            for m in re.finditer(r"(\w+)\s*=\s*(-?\d+),", ERROR_RS.read_text())
        }
        # Ok = 0 is not an error, so it has no entry in the map.
        expected = {c for c in rust_codes if c != 0}
        # noinspection PyProtectedMember
        from firewall_bridge.types import _ERROR_MAP
        assert set(_ERROR_MAP) == expected, (
            f"rust={sorted(expected)} python={sorted(_ERROR_MAP)}"
        )
