### Service Logs

Returns WireGuard service log entries.

```bash
phantom-api core service_logs
```

```bash
phantom-api core service_logs lines=100
```

**Parameters:**

| Parameter | Required | Default | Description            |
|-----------|----------|---------|------------------------|
| `lines`   | No       | 50      | Number of log lines    |

**Response Model:** [`ServiceLogs`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/core/models/service_models.py#L140)

| Field             | Type    | Description                |
|-------------------|---------|----------------------------|
| `logs`            | array   | Log entries                |
| `count`           | integer | Number of lines returned   |
| `service`         | string  | Service name               |
| `lines_requested` | integer | Lines requested            |
| `source`          | string  | Log source (journald/file) |

??? example "Example Response"
    ```json
    {
      "success": true,
      "data": {
        "logs": [
          "Sep 09 01:11:47 server wg-quick[1234]: [#] ip link add wg_main type wireguard",
          "Sep 09 01:11:47 server wg-quick[1234]: [#] wg setconf wg_main /dev/fd/63"
        ],
        "count": 2,
        "service": "wg-quick@wg_main",
        "lines_requested": 50,
        "source": "journald"
      },
      "metadata": {
        "module": "core",
        "action": "service_logs",
        "timestamp": "2025-09-09T01:15:10.000000Z",
        "version": "core-v1"
      }
    }
    ```
