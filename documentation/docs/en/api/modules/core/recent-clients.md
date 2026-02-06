### Latest Clients

Returns the most recently added clients.

```bash
phantom-api core latest_clients
```

```bash
phantom-api core latest_clients count=10
```

**Parameters:**

| Parameter | Required | Default | Description          |
|-----------|----------|---------|----------------------|
| `count`   | No       | 5       | Number of clients    |

**Response Model:** [`LatestClientsResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/core/models/client_models.py#L167)

| Field                        | Type     | Description                |
|------------------------------|----------|----------------------------|
| `latest_clients`             | array    | List of recent clients     |
| `latest_clients[].name`      | string   | Client name                |
| `latest_clients[].ip`        | string   | Assigned IP address        |
| `latest_clients[].enabled`   | boolean  | Active status              |
| `latest_clients[].created`   | datetime | Creation timestamp         |
| `latest_clients[].connected` | boolean  | Current connection status  |
| `count`                      | integer  | Number of clients returned |
| `total_clients`              | integer  | Total clients in system    |

??? example "Example Response"
    ```json
    {
      "success": true,
      "data": {
        "latest_clients": [
          {
            "name": "john-laptop",
            "ip": "10.8.0.2",
            "enabled": true,
            "created": "2025-09-09T01:14:22.076656",
            "connected": false
          }
        ],
        "count": 1,
        "total_clients": 1
      },
      "metadata": {
        "module": "core",
        "action": "latest_clients",
        "timestamp": "2025-09-09T01:15:00.000000Z",
        "version": "core-v1"
      }
    }
    ```
