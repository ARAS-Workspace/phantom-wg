"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

Core Service Models Unit Test File

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

from phantom.modules.core.models.service_models import (
    ServiceStatus,
    ClientStatistics,
    ServerConfig,
    SystemInfo,
    FirewallConfiguration,
    InterfaceStatistics,
    ServiceLogs,
    RestartResult,
    ServiceHealth
)


class TestServiceStatus:

    def test_init_minimal(self):
        status = ServiceStatus(
            running=True,
            service_name="wg-quick@wg0"
        )
        assert status.running is True
        assert status.service_name == "wg-quick@wg0"
        assert status.started_at is None
        assert status.pid is None

    def test_init_complete(self):
        status = ServiceStatus(
            running=True,
            service_name="wg-quick@wg0",
            started_at="2025-01-01T10:00:00",
            pid="12345"
        )
        assert status.running is True
        assert status.service_name == "wg-quick@wg0"
        assert status.started_at == "2025-01-01T10:00:00"
        assert status.pid == "12345"

    def test_to_dict_minimal(self):
        status = ServiceStatus(
            running=False,
            service_name="wireguard"
        )
        assert status.to_dict() == {
            "running": False,
            "service_name": "wireguard"
        }

    def test_to_dict_complete(self):
        status = ServiceStatus(
            running=True,
            service_name="wg-quick@wg0",
            started_at="2025-01-01T10:00:00",
            pid="54321"
        )
        assert status.to_dict() == {
            "running": True,
            "service_name": "wg-quick@wg0",
            "started_at": "2025-01-01T10:00:00",
            "pid": "54321"
        }


class TestClientStatistics:

    def test_init(self):
        stats = ClientStatistics(
            total_configured=50,
            enabled_clients=45,
            disabled_clients=5,
            active_connections=30
        )
        assert stats.total_configured == 50
        assert stats.enabled_clients == 45
        assert stats.disabled_clients == 5
        assert stats.active_connections == 30

    def test_to_dict(self):
        stats = ClientStatistics(
            total_configured=100,
            enabled_clients=80,
            disabled_clients=20,
            active_connections=75
        )
        assert stats.to_dict() == {
            "total_configured": 100,
            "enabled_clients": 80,
            "disabled_clients": 20,
            "active_connections": 75
        }

    def test_zero_clients(self):
        stats = ClientStatistics(
            total_configured=0,
            enabled_clients=0,
            disabled_clients=0,
            active_connections=0
        )
        assert stats.total_configured == 0
        assert stats.active_connections == 0


class TestServerConfig:

    def test_init(self):
        config = ServerConfig(
            interface="wg0",
            config_file="/etc/wireguard/wg0.conf",
            port=51820,
            network="10.0.0.0/24",
            dns=["9.9.9.9", "1.1.1.1"],
            config_exists=True
        )
        assert config.interface == "wg0"
        assert config.config_file == "/etc/wireguard/wg0.conf"
        assert config.port == 51820
        assert config.network == "10.0.0.0/24"
        assert config.dns == ["9.9.9.9", "1.1.1.1"]
        assert config.config_exists is True

    def test_to_dict(self):
        config = ServerConfig(
            interface="wg1",
            config_file="/etc/wireguard/wg1.conf",
            port=51821,
            network="192.168.100.0/24",
            dns=["1.1.1.1", "1.0.0.1"],
            config_exists=False
        )
        assert config.to_dict() == {
            "interface": "wg1",
            "config_file": "/etc/wireguard/wg1.conf",
            "port": 51821,
            "network": "192.168.100.0/24",
            "dns": ["1.1.1.1", "1.0.0.1"],
            "config_exists": False
        }

    def test_multiple_dns_servers(self):
        config = ServerConfig(
            interface="wg0",
            config_file="/etc/wireguard/wg0.conf",
            port=51820,
            network="10.0.0.0/24",
            dns=["9.9.9.9", "149.112.112.112", "1.1.1.1", "1.0.0.1"],
            config_exists=True
        )
        assert len(config.dns) == 4


class TestSystemInfo:

    def test_init(self):
        system = SystemInfo(
            install_dir="/opt/phantom",
            config_dir="/etc/phantom",
            data_dir="/var/lib/phantom",
            firewall={"status": "active", "rules": "configured"},
            wireguard_module=True
        )
        assert system.install_dir == "/opt/phantom"
        assert system.config_dir == "/etc/phantom"
        assert system.data_dir == "/var/lib/phantom"
        assert system.firewall["status"] == "active"
        assert system.wireguard_module is True

    def test_to_dict(self):
        system = SystemInfo(
            install_dir="/usr/local/phantom",
            config_dir="/etc/phantom/config",
            data_dir="/var/phantom/data",
            firewall={"ufw": "enabled", "iptables": "configured"},
            wireguard_module=False
        )
        assert system.to_dict() == {
            "install_dir": "/usr/local/phantom",
            "config_dir": "/etc/phantom/config",
            "data_dir": "/var/phantom/data",
            "firewall": {"ufw": "enabled", "iptables": "configured"},
            "wireguard_module": False
        }


class TestFirewallConfiguration:

    def test_init(self):
        firewall = FirewallConfiguration(
            ufw={"status": "active", "rules": 10},
            iptables={"chains": 5, "rules": 20},
            nat={"enabled": True, "rules": 3},
            ports={"51820": "open", "22": "open"},
            status="configured"
        )
        assert firewall.ufw["status"] == "active"
        assert firewall.iptables["chains"] == 5
        assert firewall.nat["enabled"] is True
        assert firewall.ports["51820"] == "open"
        assert firewall.status == "configured"

    def test_to_dict(self):
        firewall = FirewallConfiguration(
            ufw={"status": "inactive"},
            iptables={"status": "not_configured"},
            nat={"enabled": False},
            ports={"51820": "closed"},
            status="partial"
        )
        assert firewall.to_dict() == {
            "ufw": {"status": "inactive"},
            "iptables": {"status": "not_configured"},
            "nat": {"enabled": False},
            "ports": {"51820": "closed"},
            "status": "partial"
        }

    def test_complex_configuration(self):
        firewall = FirewallConfiguration(
            ufw={
                "status": "active",
                "rules": ["allow 51820/udp", "allow 22/tcp"],
                "default": "deny"
            },
            iptables={
                "filter": {"INPUT": 10, "FORWARD": 5, "OUTPUT": 3},
                "nat": {"PREROUTING": 2, "POSTROUTING": 4}
            },
            nat={
                "enabled": True,
                "masquerade": "10.0.0.0/24",
                "forward": True
            },
            ports={
                "51820": "open",
                "22": "open",
                "443": "closed",
                "80": "closed"
            },
            status="fully_configured"
        )
        assert len(firewall.ports) == 4
        assert firewall.nat["masquerade"] == "10.0.0.0/24"


class TestInterfaceStatistics:

    def test_init_minimal(self):
        interface = InterfaceStatistics(
            active=True,
            interface="wg0",
            peers=[]
        )
        assert interface.active is True
        assert interface.interface == "wg0"
        assert interface.peers == []
        assert interface.public_key is None
        assert interface.port is None
        assert interface.rx_bytes is None
        assert interface.tx_bytes is None

    def test_init_complete(self):
        peers = [
            {"public_key": "peer1", "endpoint": "1.2.3.4:51820"},
            {"public_key": "peer2", "endpoint": "5.6.7.8:51820"}
        ]
        interface = InterfaceStatistics(
            active=True,
            interface="wg0",
            peers=peers,
            public_key="server_public_key",
            port=51820,
            rx_bytes=1048576,
            tx_bytes=2097152
        )
        assert interface.active is True
        assert interface.interface == "wg0"
        assert len(interface.peers) == 2
        assert interface.public_key == "server_public_key"
        assert interface.port == 51820
        assert interface.rx_bytes == 1048576
        assert interface.tx_bytes == 2097152

    def test_to_dict_minimal(self):
        interface = InterfaceStatistics(
            active=False,
            interface="wg1",
            peers=[]
        )
        assert interface.to_dict() == {
            "active": False,
            "interface": "wg1",
            "peers": []
        }

    def test_to_dict_complete(self):
        peers = [{"public_key": "peer1", "allowed_ips": "10.0.0.2/32"}]
        interface = InterfaceStatistics(
            active=True,
            interface="wg0",
            peers=peers,
            public_key="server_key",
            port=51820,
            rx_bytes=5000000,
            tx_bytes=10000000
        )
        assert interface.to_dict() == {
            "active": True,
            "interface": "wg0",
            "peers": [{"public_key": "peer1", "allowed_ips": "10.0.0.2/32"}],
            "public_key": "server_key",
            "port": 51820,
            "rx_bytes": 5000000,
            "tx_bytes": 10000000
        }

    def test_zero_bytes(self):
        interface = InterfaceStatistics(
            active=True,
            interface="wg0",
            peers=[],
            rx_bytes=0,
            tx_bytes=0
        )
        result = interface.to_dict()
        assert result["rx_bytes"] == 0
        assert result["tx_bytes"] == 0


class TestServiceLogs:

    def test_init_minimal(self):
        logs = ServiceLogs(
            logs=["Log line 1", "Log line 2"],
            count=2,
            service="wireguard",
            lines_requested=10
        )
        assert logs.logs == ["Log line 1", "Log line 2"]
        assert logs.count == 2
        assert logs.service == "wireguard"
        assert logs.lines_requested == 10
        assert logs.source is None
        assert logs.file is None
        assert logs.message is None

    def test_init_complete(self):
        logs = ServiceLogs(
            logs=["Starting service", "Service started"],
            count=2,
            service="wg-quick@wg0",
            lines_requested=100,
            source="systemd",
            file="/var/log/wireguard.log",
            message="Logs retrieved successfully"
        )
        assert logs.count == 2
        assert logs.service == "wg-quick@wg0"
        assert logs.lines_requested == 100
        assert logs.source == "systemd"
        assert logs.file == "/var/log/wireguard.log"
        assert logs.message == "Logs retrieved successfully"

    def test_to_dict_minimal(self):
        logs = ServiceLogs(
            logs=[],
            count=0,
            service="wireguard",
            lines_requested=50
        )
        assert logs.to_dict() == {
            "logs": [],
            "count": 0,
            "service": "wireguard",
            "lines_requested": 50
        }

    def test_to_dict_complete(self):
        log_lines = ["Line 1", "Line 2", "Line 3"]
        logs = ServiceLogs(
            logs=log_lines,
            count=3,
            service="wg-quick",
            lines_requested=10,
            source="journalctl",
            file="/var/log/syslog",
            message="Retrieved from journal"
        )
        assert logs.to_dict() == {
            "logs": log_lines,
            "count": 3,
            "service": "wg-quick",
            "lines_requested": 10,
            "source": "journalctl",
            "file": "/var/log/syslog",
            "message": "Retrieved from journal"
        }

    def test_empty_logs(self):
        logs = ServiceLogs(
            logs=[],
            count=0,
            service="test",
            lines_requested=100,
            message="No logs found"
        )
        assert logs.logs == []
        assert logs.count == 0
        assert logs.message == "No logs found"


class TestRestartResult:

    def test_init_success(self):
        result = RestartResult(
            restarted=True,
            service_active=True,
            interface_up=True,
            service="wg-quick@wg0",
            message="Service restarted successfully"
        )
        assert result.restarted is True
        assert result.service_active is True
        assert result.interface_up is True
        assert result.service == "wg-quick@wg0"
        assert result.message == "Service restarted successfully"

    def test_init_failure(self):
        result = RestartResult(
            restarted=False,
            service_active=False,
            interface_up=False,
            service="wireguard",
            message="Failed to restart service"
        )
        assert result.restarted is False
        assert result.service_active is False
        assert result.interface_up is False

    def test_to_dict(self):
        result = RestartResult(
            restarted=True,
            service_active=True,
            interface_up=False,
            service="wg0",
            message="Service restarted but interface down"
        )
        assert result.to_dict() == {
            "restarted": True,
            "service_active": True,
            "interface_up": False,
            "service": "wg0",
            "message": "Service restarted but interface down"
        }

    def test_partial_success(self):
        result = RestartResult(
            restarted=True,
            service_active=True,
            interface_up=False,
            service="wg-quick@wg0",
            message="Service active but interface failed"
        )
        assert result.restarted is True
        assert result.service_active is True
        assert result.interface_up is False


class TestServiceHealth:

    def test_init_and_to_dict(self):
        # Create component objects
        service_status = ServiceStatus(
            running=True,
            service_name="wg-quick@wg0",
            started_at="2025-01-01T10:00:00",
            pid="12345"
        )

        interface_stats = InterfaceStatistics(
            active=True,
            interface="wg0",
            peers=[{"public_key": "peer1"}],
            port=51820
        )

        client_stats = ClientStatistics(
            total_configured=10,
            enabled_clients=8,
            disabled_clients=2,
            active_connections=5
        )

        server_config = ServerConfig(
            interface="wg0",
            config_file="/etc/wireguard/wg0.conf",
            port=51820,
            network="10.0.0.0/24",
            dns=["9.9.9.9"],
            config_exists=True
        )

        system_info = SystemInfo(
            install_dir="/opt/phantom",
            config_dir="/etc/phantom",
            data_dir="/var/lib/phantom",
            firewall={"status": "active"},
            wireguard_module=True
        )

        # Create ServiceHealth object
        health = ServiceHealth(
            service=service_status,
            interface=interface_stats,
            clients=client_stats,
            configuration=server_config,
            system=system_info
        )

        # Test attributes
        assert health.service == service_status
        assert health.interface == interface_stats
        assert health.clients == client_stats
        assert health.configuration == server_config
        assert health.system == system_info

        # Test to_dict
        health_dict = health.to_dict()
        assert "service" in health_dict
        assert "interface" in health_dict
        assert "clients" in health_dict
        assert "configuration" in health_dict
        assert "system" in health_dict

        assert health_dict["service"]["running"] is True
        assert health_dict["interface"]["active"] is True
        assert health_dict["clients"]["total_configured"] == 10
        assert health_dict["configuration"]["port"] == 51820
        assert health_dict["system"]["wireguard_module"] is True
