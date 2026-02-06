### Server Status

Returns comprehensive server health and configuration information.

```bash
phantom-api core server_status
```

**Response Model:** [`ServiceHealth`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/core/models/service_models.py#L184)

| Field                            | Type    | Description                    |
|----------------------------------|---------|--------------------------------|
| `service.running`                | boolean | Service running status         |
| `service.service_name`           | string  | Systemd service name           |
| `service.started_at`             | string  | Service start time             |
| `interface.active`               | boolean | WireGuard interface status     |
| `interface.interface`            | string  | Interface name                 |
| `interface.public_key`           | string  | Server public key              |
| `interface.port`                 | integer | Listening port                 |
| `interface.peers`                | array   | Connected peers list           |
| `configuration.network`          | string  | VPN subnet                     |
| `configuration.dns`              | array   | DNS servers                    |
| `clients.total_configured`       | integer | Total configured clients       |
| `clients.enabled_clients`        | integer | Enabled clients count          |
| `clients.active_connections`     | integer | Current active connections     |
| `system.firewall.status`         | string  | Firewall status                |
| `system.wireguard_module`        | boolean | Kernel module loaded           |

??? example "Example Response"
    ```json
    {
      "success": true,
      "data": {
        "service": {
          "running": true,
          "service_name": "wg-quick@wg_main",
          "started_at": "Tue 2025-09-09 01:11:47 UTC"
        },
        "interface": {
          "active": true,
          "interface": "wg_main",
          "public_key": "Y/V6vf2w+AWpqz3h6DYAOHuW3ZJ3vZ0jSc8D0edVthw=",
          "port": 51820,
          "peers": [...]
        },
        "configuration": {
          "network": "10.8.0.0/24",
          "dns": ["8.8.8.8", "8.8.4.4"]
        },
        "clients": {
          "total_configured": 1,
          "enabled_clients": 1,
          "active_connections": 0
        },
        "system": {
          "firewall": {"status": "active"},
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
