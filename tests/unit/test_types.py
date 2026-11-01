"""
Unit tests for native exception hierarchy and check_result — v2.1.0
"""

import pytest

from firewall_bridge.types import (
    BridgeError,
    NftablesError,
    NetlinkError,
    InvalidParamError,
    IoError,
    PermissionDeniedError,
    GroupExistsError,
    GroupNotFoundError,
    RuleNotFoundError,
    AlreadyStartedError,
    NotStartedError,
    check_result,
)


class TestExceptionHierarchy:
    def test_all_inherit_from_bridge_error(self):
        for cls in (
            NftablesError, NetlinkError, InvalidParamError,
            IoError, PermissionDeniedError,
            GroupNotFoundError, GroupExistsError, RuleNotFoundError,
            AlreadyStartedError, NotStartedError,
        ):
            assert issubclass(cls, BridgeError)

    def test_bridge_error_is_exception(self):
        assert issubclass(BridgeError, Exception)

    def test_catch_specific(self):
        with pytest.raises(NftablesError):
            raise NftablesError("nft failed")

    def test_catch_base(self):
        with pytest.raises(BridgeError):
            raise GroupNotFoundError("not found")

    def test_message_preserved(self):
        err = PermissionDeniedError("need CAP_NET_ADMIN")
        assert "need CAP_NET_ADMIN" in str(err)
        assert err.message == "need CAP_NET_ADMIN"


class TestCheckResult:
    def test_zero_passes(self):
        check_result(0)

    def test_positive_passes(self):
        check_result(1)
        check_result(42)

    def test_nftables_error(self):
        with pytest.raises(NftablesError):
            check_result(-3, "nft fail")

    def test_netlink_error(self):
        with pytest.raises(NetlinkError):
            check_result(-4, "netlink fail")

    def test_invalid_param(self):
        with pytest.raises(InvalidParamError):
            check_result(-5, "bad param")

    def test_io_error(self):
        with pytest.raises(IoError):
            check_result(-6, "io fail")

    def test_permission_denied(self):
        with pytest.raises(PermissionDeniedError):
            check_result(-7, "no perm")

    def test_unknown_code_raises_base(self):
        from unittest.mock import patch
        with patch("firewall_bridge._ffi.get_last_error", return_value=""):
            with pytest.raises(BridgeError, match="FFI error code: -99"):
                check_result(-99)

    def test_ffi_detail_fetch(self):
        from unittest.mock import patch
        with patch("firewall_bridge._ffi.get_last_error", return_value="rust error msg"):
            with pytest.raises(NftablesError, match="rust error msg"):
                check_result(-3)
