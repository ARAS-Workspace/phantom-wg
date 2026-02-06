### Remove Client

Removes a WireGuard client from the server.

```bash
phantom-api core remove_client client_name="john-laptop"
```

**Parameters:**

| Parameter     | Required | Description                   |
|---------------|----------|-------------------------------|
| `client_name` | Yes      | Name of the client to remove  |

**Response Model:** [`ClientRemoveResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/core/models/client_models.py#L133)

| Field         | Type    | Description                    |
|---------------|---------|--------------------------------|
| `removed`     | boolean | Whether removal was successful |
| `client_name` | string  | Name of the removed client     |
| `client_ip`   | string  | IP address of removed client   |

??? example "Example Response"
    ```json
    {
      "success": true,
      "data": {
        "removed": true,
        "client_name": "john-laptop",
        "client_ip": "10.8.0.2"
      },
      "metadata": {
        "module": "core",
        "action": "remove_client",
        "timestamp": "2025-09-09T01:16:45.684652Z",
        "version": "core-v1"
      }
    }
    ```
