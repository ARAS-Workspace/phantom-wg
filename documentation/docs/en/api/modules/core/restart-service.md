### Restart Service

**Warning:** All connected clients will be temporarily disconnected during restart.
```bash
phantom-api core restart_service
```

**Response:**
```json
{
  "success": true,
  "data": {
    "restarted": true,
    "service_active": true,
    "interface_up": true,
    "message": "Service restarted successfully"
  }
}
```
