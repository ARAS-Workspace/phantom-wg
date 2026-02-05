### Disable Ghost Mode

```bash
phantom-api ghost disable
```

**Response:**
```json
{
  "success": true,
  "data": {
    "status": "inactive",
    "message": "Ghost Mode disabled successfully",
    "restored": true
  },
  "metadata": {
    "module": "ghost",
    "action": "disable",
    "timestamp": "2025-09-09T01:43:07.217952Z",
    "version": "core-v1"
  }
}
```

**Notes:**

- Restores direct WireGuard connection on port 51820
- All clients automatically revert to standard WireGuard configuration
