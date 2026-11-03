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

Unit tests for exception hierarchy and check_result.
"""

import pytest

from wireguard_go_bridge.types import (
    BridgeError,
    TunCreateError,
    DeviceCreateError,
    IpcError,
    DeviceNotFoundError,
    DeviceUpError,
    DeviceDownError,
    InvalidArgumentError,
    check_result,
)


class TestExceptionHierarchy:
    def test_all_inherit_from_bridge_error(self):
        for cls in (TunCreateError, DeviceCreateError, IpcError,
                    DeviceNotFoundError, DeviceUpError, DeviceDownError,
                    InvalidArgumentError):
            assert issubclass(cls, BridgeError)

    def test_tun_create_is_a_device_create_error(self):
        assert issubclass(TunCreateError, DeviceCreateError)

    def test_invalid_argument_is_a_value_error(self):
        assert issubclass(InvalidArgumentError, ValueError)

    def test_bridge_error_is_exception(self):
        assert issubclass(BridgeError, Exception)

    def test_catch_specific(self):
        with pytest.raises(DeviceUpError):
            raise DeviceUpError("test")

    def test_catch_base(self):
        with pytest.raises(BridgeError):
            raise IpcError("test")

    def test_message_preserved(self):
        err = TunCreateError("no /dev/net/tun")
        assert "no /dev/net/tun" in str(err)


class TestCheckResult:
    def test_zero_passes(self):
        check_result(0)

    def test_positive_passes(self):
        check_result(1)
        check_result(42)

    def test_tun_create(self):
        with pytest.raises(TunCreateError):
            check_result(-2)

    def test_device_create(self):
        with pytest.raises(DeviceCreateError):
            check_result(-3)

    def test_ipc_set(self):
        with pytest.raises(IpcError):
            check_result(-4)

    def test_not_found(self):
        with pytest.raises(DeviceNotFoundError):
            check_result(-5)

    def test_device_up(self):
        with pytest.raises(DeviceUpError):
            check_result(-7)

    def test_device_down(self):
        with pytest.raises(DeviceDownError):
            check_result(-8)

    def test_invalid_argument(self):
        with pytest.raises(InvalidArgumentError):
            check_result(-10)

    def test_internal(self):
        with pytest.raises(BridgeError):
            check_result(-99)

    def test_message_and_code(self):
        with pytest.raises(IpcError) as exc:
            check_result(-4, "config applied, state not persisted: disk full")
        assert str(exc.value) == "config applied, state not persisted: disk full"
        assert exc.value.code == -4

    def test_no_message_names_the_code(self):
        with pytest.raises(DeviceUpError, match="FFI error code: -7") as exc:
            check_result(-7)
        assert exc.value.code == -7

    def test_unknown_code_raises_base(self):
        with pytest.raises(BridgeError, match="FFI error code: -42"):
            check_result(-42)