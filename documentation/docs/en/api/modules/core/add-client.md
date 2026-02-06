### Add Client

Adds a new WireGuard client to the server.

```bash
phantom-api core add_client client_name="john-laptop"
```

**Parameters:**

| Parameter     | Required | Description                                       |
|---------------|----------|---------------------------------------------------|
| `client_name` | Yes      | Alphanumeric characters, hyphens, and underscores |

**Response Model:** [`ClientAddResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/core/models/client_models.py#L58)

| Field               | Type     | Description              |
|---------------------|----------|--------------------------|
| `client.name`       | string   | Client name              |
| `client.ip`         | string   | Assigned IP address      |
| `client.public_key` | string   | WireGuard public key     |
| `client.created`    | datetime | Creation timestamp       |
| `client.enabled`    | boolean  | Active status            |
| `message`           | string   | Operation result message |

??? example "Example Response"
    ```json
    {
      "success": true,
      "data": {
        "client": {
          "name": "john-laptop",
          "ip": "10.8.0.2",
          "public_key": "SKv9YRp0MgHuMCthVIMBRs4Jfwb+mO3vbfvm9jOrLSY=",
          "created": "2025-09-09T01:14:22.076656",
          "enabled": true
        },
        "message": "Client added successfully"
      },
      "metadata": {
        "module": "core",
        "action": "add_client",
        "timestamp": "2025-09-09T01:14:22.119132Z",
        "version": "core-v1"
      }
    }
    ```
