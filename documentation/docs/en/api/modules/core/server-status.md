### Server Status
```bash
phantom-api core server_status
```

**Response:**
```json
{
  "success": true,
  "data": {
    "service": {
      "running": true,
      "service_name": "wg-quick@wg_main",
      "started_at": "Tue 2025-09-09 01:11:47 UTC",
      "pid": "0"
    },
    "interface": {
      "active": true,
      "interface": "wg_main",
      "peers": [
        {
          "public_key": "SKv9YRp0MgHuMCthVIMBRs4Jfwb+mO3vbfvm9jOrLSY=",
          "preshared_key": "(hidden)",
          "allowed_ips": "10.8.0.2/32"
        }
      ],
      "public_key": "Y/V6vf2w+AWpqz3h6DYAOHuW3ZJ3vZ0jSc8D0edVthw=",
      "port": 51820,
      "rx_bytes": 0,
      "tx_bytes": 0
    },
    "configuration": {
      "interface": "wg_main",
      "config_file": "/etc/wireguard/wg_main.conf",
      "port": 51820,
      "network": "10.8.0.0/24",
      "dns": [
        "8.8.8.8",
        "8.8.4.4"
      ],
      "config_exists": true
    },
    "clients": {
      "total_configured": 1,
      "enabled_clients": 1,
      "disabled_clients": 0,
      "active_connections": 0
    },
    "system": {
      "install_dir": "/opt/phantom-wg",
      "config_dir": "/opt/phantom-wg/config",
      "data_dir": "/opt/phantom-wg/data",
      "firewall": {
        "status": "active"
      },
      "wireguard_module": true
    }
  },
  "metadata": {
    "module": "core",
    "action": "server_status",
    "timestamp": "2025-09-09T01:15:03.512070Z",
    "version": "core-v1"
  }
}
```
