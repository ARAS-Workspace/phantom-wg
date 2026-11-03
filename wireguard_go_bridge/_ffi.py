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

Low-level ctypes bindings to wireguard_go_bridge.so.
PersistentDevice + Key generation + utility only.
"""

import ctypes
import ctypes.util
import os
import platform
from typing import Optional

_lib: Optional[ctypes.CDLL] = None


def _resolve_platform() -> tuple[str, str]:
    system = platform.system().lower()
    arch = platform.machine()
    ext = ".dylib" if system == "darwin" else ".so"
    lib_name = f"wireguard_go_bridge{ext}"
    arch_map = {
        ("linux", "x86_64"): "linux-amd64",
        ("linux", "aarch64"): "linux-arm64",
        ("linux", "arm64"): "linux-arm64",
        ("darwin", "arm64"): "darwin-arm64",
        ("darwin", "x86_64"): "darwin-amd64",
    }
    arch_dir = arch_map.get((system, arch), f"{system}-{arch}")
    return lib_name, arch_dir


def _find_library() -> str:
    env_path = os.environ.get("WIREGUARD_GO_BRIDGE_LIB_PATH")
    if env_path and os.path.isfile(env_path):
        return env_path

    lib_name, _ = _resolve_platform()

    sibling_path = os.path.join(os.path.dirname(__file__), lib_name)
    if os.path.isfile(sibling_path):
        return sibling_path

    found = ctypes.util.find_library("wireguard_go_bridge")
    if found:
        return found

    raise FileNotFoundError(
        f"{lib_name} not found. Set WIREGUARD_GO_BRIDGE_LIB_PATH environment variable."
    )


def _load_library() -> ctypes.CDLL:
    global _lib
    if _lib is None:
        path = _find_library()
        _lib = ctypes.CDLL(path)
        _setup_signatures(_lib)
    return _lib


def get_lib() -> ctypes.CDLL:
    return _load_library()


def _setup_signatures(lib: ctypes.CDLL) -> None:
    """Define the C function signatures."""

    c_p = ctypes.c_char_p
    c_vp = ctypes.c_void_p
    c_i32 = ctypes.c_int32
    c_i64 = ctypes.c_int64

    # ---- PersistentDevice ----

    lib.NewPersistentDevice.argtypes = [c_p, ctypes.c_int, c_p]
    lib.NewPersistentDevice.restype = c_i64

    lib.DeviceIpcSet.argtypes = [c_i64, c_p]
    lib.DeviceIpcSet.restype = c_i32

    lib.DeviceIpcGet.argtypes = [c_i64]
    lib.DeviceIpcGet.restype = c_vp

    lib.DeviceUp.argtypes = [c_i64]
    lib.DeviceUp.restype = c_i32

    lib.DeviceDown.argtypes = [c_i64]
    lib.DeviceDown.restype = c_i32

    lib.DeviceClose.argtypes = [c_i64]
    lib.DeviceClose.restype = c_i32

    # ---- Key Generation ----

    lib.GeneratePrivateKey.argtypes = []
    lib.GeneratePrivateKey.restype = c_vp

    lib.DerivePublicKey.argtypes = [c_p]
    lib.DerivePublicKey.restype = c_vp

    lib.GeneratePresharedKey.argtypes = []
    lib.GeneratePresharedKey.restype = c_vp

    lib.HexToBase64.argtypes = [c_p]
    lib.HexToBase64.restype = c_vp

    # ---- Utility ----

    lib.BridgeVersion.argtypes = []
    lib.BridgeVersion.restype = c_vp

    lib.FreeString.argtypes = [c_p]
    lib.FreeString.restype = None

    lib.LastError.argtypes = [ctypes.POINTER(c_i32)]
    lib.LastError.restype = c_vp


def _read_and_free(ptr) -> str:
    """Read a Go-allocated C string and free it."""
    if not ptr:
        return ""
    s = ctypes.cast(ptr, ctypes.c_char_p)
    text = s.value.decode("utf-8") if s.value else ""
    get_lib().FreeString(s)
    return text


def get_bridge_version() -> str:
    return _read_and_free(get_lib().BridgeVersion()) or "unknown"


def last_error(lib: ctypes.CDLL) -> tuple[int, str]:
    """The calling thread's last error: the code and the message the
    bridge recorded for this thread's last call, or (0, "") when that
    call succeeded."""
    code = ctypes.c_int32(0)
    ptr = lib.LastError(ctypes.byref(code))
    message = ""
    if ptr:
        s = ctypes.cast(ptr, ctypes.c_char_p)
        message = s.value.decode("utf-8", errors="replace") if s.value else ""
        lib.FreeString(s)
    return code.value, message
