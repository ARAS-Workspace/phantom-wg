### Ghost Mode Status

Retrieves the current Ghost Mode status and configuration details.

```bash
phantom-api ghost status
```

**Response Model:** [`GhostStatusResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/ghost/models/ghost_models.py#L72)

| Field                | Type    | Description                              |
|----------------------|---------|------------------------------------------|
| `status`             | string  | Current status (active/inactive)         |
| `enabled`            | boolean | Ghost Mode enabled                       |
| `message`            | string  | Status message (when inactive)           |
| `server_ip`          | string  | Server's public IP (when active)         |
| `domain`             | string  | Configured domain (when active)          |
| `secret`             | string  | WebSocket secret (when active)           |
| `protocol`           | string  | Tunnel protocol (when active)            |
| `port`               | integer | HTTPS port (when active)                 |
| `services.wstunnel`  | string  | wstunnel service status (when active)    |
| `activated_at`       | string  | Activation timestamp (when active)       |
| `connection_command` | string  | wstunnel command (when active)           |
| `client_export_info` | string  | Client export info (when active)         |

??? example "Example Response (Inactive)"
    ```json
    {
      "success": true,
      "data": {
        "status": "inactive",
        "enabled": false,
        "message": "Ghost Mode is not active"
      }
    }
    ```

??? example "Example Response (Active)"
    ```json
    {
      "success": true,
      "data": {
        "status": "active",
        "enabled": true,
        "server_ip": "157.230.114.231",
        "domain": "157-230-114-231.sslip.io",
        "secret": "Ui1RVMCxicaByr7C5XrgqS5yCilLmkCAXMcF8oZP4ZcVkQAvZhRCht3hsHeJENac",
        "protocol": "wss",
        "port": 443,
        "services": {
          "wstunnel": "active"
        },
        "activated_at": "2025-09-09T01:41:24.079841",
        "connection_command": "wstunnel client --http-upgrade-path-prefix \"Ui1RVMCxicaByr7C5XrgqS5yCilLmkCAXMcF8oZP4ZcVkQAvZhRCht3hsHeJENac\" -L udp://127.0.0.1:51820:127.0.0.1:51820 wss://157-230-114-231.sslip.io:443",
        "client_export_info": "Use 'phantom-casper <client_name>' to export client configurations"
      }
    }
    ```
