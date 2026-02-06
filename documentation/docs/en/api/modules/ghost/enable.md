### Enable Ghost Mode

Enables Ghost Mode to tunnel WireGuard traffic through HTTPS/WebSocket, making it appear as normal web traffic.

```bash
phantom-api ghost enable domain="cdn.example.com"
```

```bash
phantom-api ghost enable domain="157-230-114-231.sslip.io"
```

**Parameters:**

| Parameter | Required | Description                                                        |
|-----------|----------|--------------------------------------------------------------------|
| `domain`  | Yes      | Domain with A record pointing to server (supports sslip.io/nip.io) |

**Response Model:** [`EnableGhostResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/ghost/models/ghost_models.py#L22)

| Field                | Type     | Description                               |
|----------------------|----------|-------------------------------------------|
| `status`             | string   | Ghost Mode status (active)                |
| `server_ip`          | string   | Server's public IP address                |
| `domain`             | string   | Domain used for tunneling                 |
| `secret`             | string   | Unique token for WebSocket authentication |
| `protocol`           | string   | Tunnel protocol (wss)                     |
| `port`               | integer  | HTTPS port (443)                          |
| `activated_at`       | datetime | Activation timestamp                      |
| `connection_command` | string   | Complete wstunnel command for clients     |

!!! info "Notes"
    - `secret` is a unique token generated for secure WebSocket tunneling
    - `connection_command` shows the complete wstunnel command that clients need to run

??? example "Example Response"
    ```json
    {
      "success": true,
      "data": {
        "status": "active",
        "server_ip": "157.230.114.231",
        "domain": "157-230-114-231.sslip.io",
        "secret": "Ui1RVMCxicaByr7C5XrgqS5yCilLmkCAXMcF8oZP4ZcVkQAvZhRCht3hsHeJENac",
        "protocol": "wss",
        "port": 443,
        "activated_at": "2025-09-09T01:41:24.079841",
        "connection_command": "wstunnel client --http-upgrade-path-prefix \"Ui1RVMCxicaByr7C5XrgqS5yCilLmkCAXMcF8oZP4ZcVkQAvZhRCht3hsHeJENac\" -L udp://127.0.0.1:51820:127.0.0.1:51820 wss://157-230-114-231.sslip.io:443"
      }
    }
    ```
