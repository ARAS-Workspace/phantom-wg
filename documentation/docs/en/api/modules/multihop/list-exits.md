### List Exit Points

```bash
phantom-api multihop list_exits
```

**Response:**
```json
{
  "success": true,
  "data": {
    "exits": [
      {
        "name": "xeovo-uk",
        "endpoint": "uk.gw.xeovo.com:51820",
        "active": false,
        "provider": "Unknown Provider",
        "imported_at": "2025-09-09T01:16:21.977967",
        "multihop_enhanced": true
      }
    ],
    "multihop_enabled": false,
    "active_exit": null,
    "total": 1
  },
  "metadata": {
    "module": "multihop",
    "action": "list_exits",
    "timestamp": "2025-09-09T01:16:30.162946Z",
    "version": "core-v1"
  }
}
```
