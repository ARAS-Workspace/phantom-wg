### Enable Ghost Mode

```bash
# Enable with custom domain
phantom-api ghost enable domain="cdn.example.com"

# Enable with sslip.io (automatic wildcard SSL)
phantom-api ghost enable domain="157-230-114-231.sslip.io"
```

**Parameters:**
- `domain` (required): Domain with A record pointing to the server (supports sslip.io/nip.io)

**Response:**
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
  },
  "metadata": {
    "module": "ghost",
    "action": "enable",
    "timestamp": "2025-09-09T01:41:32.236798Z",
    "version": "core-v1"
  }
}
```

**Notes:**

- `secret` is a unique token generated for secure WebSocket tunneling
- `connection_command` shows the complete wstunnel command that clients need to run
