### Get Session Log

Retrieves the multihop session log with connection events and status changes.

```bash
phantom-api multihop get_session_log
```

```bash
phantom-api multihop get_session_log lines=100
```

**Parameters:**

| Parameter | Required | Description                               |
|-----------|----------|-------------------------------------------|
| `lines`   | No       | Number of lines to retrieve (default: 50) |

**Response Model:** [`SessionLog`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/multihop/models/multihop_models.py#L182)

| Field                | Type   | Description                              |
|----------------------|--------|------------------------------------------|
| `logs[].timestamp`   | string | Event timestamp                          |
| `logs[].exit_name`   | string | Exit point name                          |
| `logs[].event`       | string | Event type                               |
| `logs[].details`     | object | Additional event details                 |

??? example "Example Response"
    ```json
    {
      "success": true,
      "data": {
        "logs": [
          {
            "timestamp": "2025-09-09T01:20:00.000000",
            "exit_name": "xeovo-uk",
            "event": "enabled",
            "details": {
              "endpoint": "uk.gw.xeovo.com:51820",
              "handshake": true
            }
          },
          {
            "timestamp": "2025-09-09T01:25:00.000000",
            "exit_name": "xeovo-uk",
            "event": "health_check",
            "details": {
              "status": "healthy"
            }
          }
        ]
      }
    }
    ```
