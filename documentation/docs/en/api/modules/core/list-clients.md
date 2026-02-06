### List Clients

Lists all WireGuard clients with pagination and search support.

```bash
phantom-api core list_clients
```

```bash
phantom-api core list_clients page=2 per_page=20
```

```bash
phantom-api core list_clients search="john"
```

**Parameters:**

| Parameter  | Required | Default | Description        |
|------------|----------|---------|--------------------|
| `page`     | No       | 1       | Page number        |
| `per_page` | No       | 10      | Items per page     |
| `search`   | No       | -       | Search term        |

**Response Model:** [`ClientListResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/core/models/client_models.py#L119)

| Field                      | Type     | Description                 |
|----------------------------|----------|-----------------------------|
| `clients`                  | array    | List of client objects      |
| `clients[].name`           | string   | Client name                 |
| `clients[].ip`             | string   | Assigned IP address         |
| `clients[].enabled`        | boolean  | Active status               |
| `clients[].created`        | datetime | Creation timestamp          |
| `clients[].connected`      | boolean  | Current connection status   |
| `total`                    | integer  | Total number of clients     |
| `pagination.page`          | integer  | Current page number         |
| `pagination.per_page`      | integer  | Items per page              |
| `pagination.total_pages`   | integer  | Total number of pages       |
| `pagination.has_next`      | boolean  | Has next page               |
| `pagination.has_prev`      | boolean  | Has previous page           |

??? example "Example Response"
    ```json
    {
      "success": true,
      "data": {
        "total": 1,
        "clients": [
          {
            "name": "john-laptop",
            "ip": "10.8.0.2",
            "enabled": true,
            "created": "2025-09-09T01:14:22.076656",
            "connected": false
          }
        ],
        "pagination": {
          "page": 1,
          "per_page": 10,
          "total_pages": 1,
          "has_next": false,
          "has_prev": false,
          "showing_from": 1,
          "showing_to": 1
        }
      },
      "metadata": {
        "module": "core",
        "action": "list_clients",
        "timestamp": "2025-09-09T01:14:32.551562Z",
        "version": "core-v1"
      }
    }
    ```
