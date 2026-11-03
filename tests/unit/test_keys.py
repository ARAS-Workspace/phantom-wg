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

Unit tests for key generation — mocked FFI.
Patches _read_and_free to avoid real ctypes pointer operations in unit tests.
"""

from unittest.mock import MagicMock, patch

import pytest

from wireguard_go_bridge.keys import (
    generate_private_key,
    derive_public_key,
    generate_preshared_key,
    hex_to_base64,
)
from wireguard_go_bridge.types import InvalidArgumentError


@pytest.fixture(autouse=True)
def recorded():
    """The bridge's record of the last call, (code, message); no record
    unless a test sets one."""
    with patch("wireguard_go_bridge.keys.last_error", return_value=(0, "")) as last_error:
        yield last_error


MOCK_PRIV_HEX = "a" * 64
MOCK_PUB_HEX = "b" * 64
MOCK_PSK_HEX = "c" * 64
MOCK_B64 = "qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqs="


class TestGeneratePrivateKey:
    def test_success(self):
        lib = MagicMock()
        lib.GeneratePrivateKey.return_value = 0xDEAD
        with patch("wireguard_go_bridge.keys.get_lib", return_value=lib), \
             patch("wireguard_go_bridge.keys._read_and_free", return_value=MOCK_PRIV_HEX):
            key = generate_private_key()
        assert key == MOCK_PRIV_HEX

    def test_failure_raises(self):
        lib = MagicMock()
        lib.GeneratePrivateKey.return_value = None
        with patch("wireguard_go_bridge.keys.get_lib", return_value=lib), \
             patch("wireguard_go_bridge.keys._read_and_free", return_value=""):
            with pytest.raises(RuntimeError, match="Failed to generate"):
                generate_private_key()

    def test_failure_carries_the_recorded_message(self, recorded):
        lib = MagicMock()
        lib.GeneratePrivateKey.return_value = None
        recorded.return_value = (-99, "random read: unexpected EOF")
        with patch("wireguard_go_bridge.keys.get_lib", return_value=lib), \
             patch("wireguard_go_bridge.keys._read_and_free", return_value=""):
            with pytest.raises(RuntimeError) as exc:
                generate_private_key()
        assert str(exc.value) == "Failed to generate private key: random read: unexpected EOF"


class TestDerivePublicKey:
    def test_success(self):
        lib = MagicMock()
        lib.DerivePublicKey.return_value = 0xDEAD
        with patch("wireguard_go_bridge.keys.get_lib", return_value=lib), \
             patch("wireguard_go_bridge.keys._read_and_free", return_value=MOCK_PUB_HEX):
            pub = derive_public_key(MOCK_PRIV_HEX)
        assert pub == MOCK_PUB_HEX

    def test_failure_raises(self):
        lib = MagicMock()
        lib.DerivePublicKey.return_value = None
        with patch("wireguard_go_bridge.keys.get_lib", return_value=lib), \
             patch("wireguard_go_bridge.keys._read_and_free", return_value=""):
            with pytest.raises(ValueError, match="Failed to derive"):
                derive_public_key("bad")

    def test_refused_key_is_an_invalid_argument(self, recorded):
        lib = MagicMock()
        lib.DerivePublicKey.return_value = None
        recorded.return_value = (-10, "invalid private key hex")
        with patch("wireguard_go_bridge.keys.get_lib", return_value=lib), \
             patch("wireguard_go_bridge.keys._read_and_free", return_value=""):
            with pytest.raises(InvalidArgumentError) as exc:
                derive_public_key("bad")
        assert isinstance(exc.value, ValueError)
        assert str(exc.value) == "Failed to derive public key: invalid private key hex"
        assert exc.value.code == -10


class TestGeneratePresharedKey:
    def test_success(self):
        lib = MagicMock()
        lib.GeneratePresharedKey.return_value = 0xDEAD
        with patch("wireguard_go_bridge.keys.get_lib", return_value=lib), \
             patch("wireguard_go_bridge.keys._read_and_free", return_value=MOCK_PSK_HEX):
            psk = generate_preshared_key()
        assert psk == MOCK_PSK_HEX

    def test_failure_raises(self):
        lib = MagicMock()
        lib.GeneratePresharedKey.return_value = None
        with patch("wireguard_go_bridge.keys.get_lib", return_value=lib), \
             patch("wireguard_go_bridge.keys._read_and_free", return_value=""):
            with pytest.raises(RuntimeError, match="Failed to generate"):
                generate_preshared_key()


class TestHexToBase64:
    def test_success(self):
        lib = MagicMock()
        lib.HexToBase64.return_value = 0xDEAD
        with patch("wireguard_go_bridge.keys.get_lib", return_value=lib), \
             patch("wireguard_go_bridge.keys._read_and_free", return_value=MOCK_B64):
            b64 = hex_to_base64(MOCK_PRIV_HEX)
        assert b64 == MOCK_B64

    def test_failure_raises(self):
        lib = MagicMock()
        lib.HexToBase64.return_value = None
        with patch("wireguard_go_bridge.keys.get_lib", return_value=lib), \
             patch("wireguard_go_bridge.keys._read_and_free", return_value=""):
            with pytest.raises(ValueError, match="Failed to convert"):
                hex_to_base64("bad")