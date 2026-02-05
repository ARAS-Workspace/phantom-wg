### List Clients
```bash
# List first 10 clients
phantom-api core list_clients

# List page 2 with 20 items per page
phantom-api core list_clients page=2 per_page=20

# Search clients
phantom-api core list_clients search="john"
```

**Parameters:**

- `page` (optional, default=1): Page number
- `per_page` (optional, default=10): Items per page
- `search` (optional): Search term

**Response:**
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
