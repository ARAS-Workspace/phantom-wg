### Add Client
```bash
phantom-api core add_client client_name="john-laptop"
```

**Parameters:**

- `client_name` (required): May contain alphanumeric characters, hyphens, and underscores

**Response:**
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
