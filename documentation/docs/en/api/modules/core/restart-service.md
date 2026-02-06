### Restart Service

Restarts the WireGuard service.

!!! warning
    All connected clients will be temporarily disconnected during restart.

```bash
phantom-api core restart_service
```

**Response Model:** [`RestartResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/core/models/service_models.py#L166)

| Field            | Type    | Description                  |
|------------------|---------|------------------------------|
| `restarted`      | boolean | Restart completed            |
| `service_active` | boolean | Service is now active        |
| `interface_up`   | boolean | Interface is up              |
| `service`        | string  | Service name                 |
| `message`        | string  | Result message               |

??? example "Example Response"
    ```json
    {
      "success": true,
      "data": {
        "restarted": true,
        "service_active": true,
        "interface_up": true,
        "service": "wg-quick@wg_main",
        "message": "Service restarted successfully"
      },
      "metadata": {
        "module": "core",
        "action": "restart_service",
        "timestamp": "2025-09-09T01:16:00.000000Z",
        "version": "core-v1"
      }
    }
    ```
