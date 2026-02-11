"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

Core Util Models Unit Test File

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

from phantom.modules.core.models.util_models import (
    SuccessResponse,
    ErrorResponse,
    TransferData,
    WireGuardShowData
)


class TestSuccessResponse:

    def test_init_minimal(self):
        response = SuccessResponse(
            success=True,
            data={"result": "ok"}
        )
        assert response.success is True
        assert response.data == {"result": "ok"}
        assert response.message is None

    def test_init_with_message(self):
        response = SuccessResponse(
            success=True,
            data={"client": "added"},
            message="Client successfully added"
        )
        assert response.success is True
        assert response.data == {"client": "added"}
        assert response.message == "Client successfully added"

    def test_to_dict_minimal(self):
        response = SuccessResponse(
            success=True,
            data={"status": "active"}
        )
        assert response.to_dict() == {
            "success": True,
            "data": {"status": "active"}
        }

    def test_to_dict_with_message(self):
        response = SuccessResponse(
            success=True,
            data={"operation": "completed"},
            message="Operation completed successfully"
        )
        assert response.to_dict() == {
            "success": True,
            "data": {"operation": "completed"},
            "message": "Operation completed successfully"
        }

    def test_empty_data(self):
        response = SuccessResponse(
            success=True,
            data={}
        )
        assert response.data == {}
        result = response.to_dict()
        assert result["data"] == {}

    def test_complex_data(self):
        complex_data = {
            "clients": [
                {"name": "client1", "ip": "10.0.0.2"},
                {"name": "client2", "ip": "10.0.0.3"}
            ],
            "metadata": {
                "total": 2,
                "active": 1,
                "settings": {
                    "dns": ["9.9.9.9", "1.1.1.1"],
                    "network": "10.0.0.0/24"
                }
            },
            "timestamp": "2025-01-01T12:00:00"
        }
        response = SuccessResponse(
            success=True,
            data=complex_data,
            message="Data retrieved"
        )
        assert response.data["clients"][0]["name"] == "client1"
        assert response.data["metadata"]["settings"]["dns"][0] == "9.9.9.9"

    def test_success_false(self):
        response = SuccessResponse(
            success=False,
            data={"reason": "validation_failed"},
            message="Input validation failed"
        )
        assert response.success is False
        assert response.data["reason"] == "validation_failed"


class TestErrorResponse:

    def test_init(self):
        response = ErrorResponse(
            success=False,
            error="Client not found",
            code="CLIENT_NOT_FOUND"
        )
        assert response.success is False
        assert response.error == "Client not found"
        assert response.code == "CLIENT_NOT_FOUND"

    def test_to_dict(self):
        response = ErrorResponse(
            success=False,
            error="Invalid IP address",
            code="INVALID_IP"
        )
        assert response.to_dict() == {
            "success": False,
            "error": "Invalid IP address",
            "code": "INVALID_IP"
        }

    def test_various_error_codes(self):
        error_cases = [
            ("Network error", "NETWORK_ERROR"),
            ("Permission denied", "PERMISSION_DENIED"),
            ("Service unavailable", "SERVICE_UNAVAILABLE"),
            ("Invalid request", "INVALID_REQUEST"),
            ("Timeout occurred", "TIMEOUT"),
            ("Resource not found", "NOT_FOUND")
        ]

        for error, code in error_cases:
            response = ErrorResponse(
                success=False,
                error=error,
                code=code
            )
            assert response.error == error
            assert response.code == code

    def test_success_true_edge_case(self):
        response = ErrorResponse(
            success=True,
            error="No error",
            code="OK"
        )
        assert response.success is True
        assert response.error == "No error"
        assert response.code == "OK"

    def test_empty_strings(self):
        response = ErrorResponse(
            success=False,
            error="",
            code=""
        )
        assert response.error == ""
        assert response.code == ""
        result = response.to_dict()
        assert result["error"] == ""
        assert result["code"] == ""


class TestTransferData:

    def test_init(self):
        transfer = TransferData(
            received="1.5 GiB",
            sent="2.3 GiB",
            received_bytes=1610612736,
            sent_bytes=2469606400
        )
        assert transfer.received == "1.5 GiB"
        assert transfer.sent == "2.3 GiB"
        assert transfer.received_bytes == 1610612736
        assert transfer.sent_bytes == 2469606400

    def test_to_dict(self):
        transfer = TransferData(
            received="500 MiB",
            sent="750 MiB",
            received_bytes=524288000,
            sent_bytes=786432000
        )
        assert transfer.to_dict() == {
            "received": "500 MiB",
            "sent": "750 MiB",
            "received_bytes": 524288000,
            "sent_bytes": 786432000
        }

    def test_zero_transfer(self):
        transfer = TransferData(
            received="0 B",
            sent="0 B",
            received_bytes=0,
            sent_bytes=0
        )
        assert transfer.received_bytes == 0
        assert transfer.sent_bytes == 0

    def test_various_sizes(self):
        test_cases = [
            ("100 B", "200 B", 100, 200),
            ("1.5 KiB", "2.5 KiB", 1536, 2560),
            ("10 MiB", "20 MiB", 10485760, 20971520),
            ("1 GiB", "2 GiB", 1073741824, 2147483648),
            ("1.5 TiB", "2.0 TiB", 1649267441664, 2199023255552)
        ]

        for recv_str, sent_str, recv_bytes, sent_bytes in test_cases:
            transfer = TransferData(
                received=recv_str,
                sent=sent_str,
                received_bytes=recv_bytes,
                sent_bytes=sent_bytes
            )
            assert transfer.received == recv_str
            assert transfer.sent == sent_str
            assert transfer.received_bytes == recv_bytes
            assert transfer.sent_bytes == sent_bytes

    def test_asymmetric_transfer(self):
        transfer = TransferData(
            received="10 MiB",
            sent="10 GiB",
            received_bytes=10485760,
            sent_bytes=10737418240
        )
        assert transfer.sent_bytes > transfer.received_bytes * 1000


class TestWireGuardShowData:

    def test_init_minimal(self):
        show_data = WireGuardShowData(
            interface={},
            peers=[]
        )
        assert show_data.interface == {}
        assert show_data.peers == []

    def test_init_with_interface_data(self):
        interface_data = {
            "private_key": "(hidden)",
            "public_key": "server_public_key_123",
            "listening_port": 51820,
            "fwmark": "off"
        }
        show_data = WireGuardShowData(
            interface=interface_data,
            peers=[]
        )
        assert show_data.interface["public_key"] == "server_public_key_123"
        assert show_data.interface["listening_port"] == 51820

    def test_init_with_peers(self):
        peers_data = [
            {
                "public_key": "peer1_public_key",
                "endpoint": "192.168.1.100:51820",
                "allowed_ips": ["10.0.0.2/32"],
                "latest_handshake": "2 minutes ago",
                "transfer": {
                    "received": "100 MiB",
                    "sent": "50 MiB"
                }
            },
            {
                "public_key": "peer2_public_key",
                "endpoint": "10.20.30.40:51820",
                "allowed_ips": ["10.0.0.3/32", "192.168.100.0/24"],
                "latest_handshake": "5 seconds ago",
                "transfer": {
                    "received": "1 GiB",
                    "sent": "2 GiB"
                }
            }
        ]
        show_data = WireGuardShowData(
            interface={},
            peers=peers_data
        )
        assert len(show_data.peers) == 2
        assert show_data.peers[0]["public_key"] == "peer1_public_key"
        assert show_data.peers[1]["allowed_ips"][1] == "192.168.100.0/24"

    def test_to_dict_empty(self):
        show_data = WireGuardShowData(
            interface={},
            peers=[]
        )
        assert show_data.to_dict() == {
            "interface": {},
            "peers": []
        }

    def test_to_dict_complete(self):
        interface_data = {
            "public_key": "interface_key",
            "port": 51820,
            "peers_count": 2
        }
        peers_data = [
            {
                "public_key": "peer1",
                "endpoint": "1.2.3.4:51820",
                "allowed_ips": ["10.0.0.2/32"]
            },
            {
                "public_key": "peer2",
                "endpoint": "5.6.7.8:51820",
                "allowed_ips": ["10.0.0.3/32"]
            }
        ]
        show_data = WireGuardShowData(
            interface=interface_data,
            peers=peers_data
        )
        result = show_data.to_dict()
        assert result == {
            "interface": interface_data,
            "peers": peers_data
        }

    def test_complex_show_output(self):
        show_data = WireGuardShowData(
            interface={
                "private_key": "(hidden)",
                "public_key": "abc123def456",
                "listening_port": 51820,
                "fwmark": "off",
                "peers": 5,
                "transfer_total": {
                    "rx": "10 GiB",
                    "tx": "15 GiB"
                }
            },
            peers=[
                {
                    "public_key": "peer_complex_1",
                    "preshared_key": "(hidden)",
                    "endpoint": "[2001:db8::1]:51820",  # IPv6 endpoint
                    "allowed_ips": ["10.0.0.2/32", "fd00::2/128"],
                    "latest_handshake": "1 minute, 30 seconds ago",
                    "persistent_keepalive": 25,
                    "transfer": {
                        "rx": 1073741824,
                        "tx": 536870912
                    }
                },
                {
                    "public_key": "peer_complex_2",
                    "endpoint": "dynamic",
                    "allowed_ips": ["0.0.0.0/0", "::/0"],  # Full tunnel
                    "latest_handshake": "Never",
                    "transfer": {
                        "rx": 0,
                        "tx": 0
                    }
                }
            ]
        )
        assert show_data.interface["transfer_total"]["rx"] == "10 GiB"
        assert show_data.peers[0]["endpoint"] == "[2001:db8::1]:51820"
        assert show_data.peers[1]["latest_handshake"] == "Never"

    def test_peers_various_states(self):
        peers_data = [
            # Active peer
            {
                "public_key": "active_peer",
                "endpoint": "1.1.1.1:51820",
                "latest_handshake": "10 seconds ago",
                "status": "active"
            },
            # Inactive peer
            {
                "public_key": "inactive_peer",
                "endpoint": None,
                "latest_handshake": "Never",
                "status": "inactive"
            },
            # Roaming peer
            {
                "public_key": "roaming_peer",
                "endpoint": "dynamic",
                "latest_handshake": "2 minutes ago",
                "status": "roaming"
            }
        ]
        show_data = WireGuardShowData(
            interface={"status": "running"},
            peers=peers_data
        )
        assert show_data.peers[0]["status"] == "active"
        assert show_data.peers[1]["endpoint"] is None
        assert show_data.peers[2]["endpoint"] == "dynamic"
