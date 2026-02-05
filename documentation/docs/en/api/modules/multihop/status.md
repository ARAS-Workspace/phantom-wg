### Multihop Status

```bash
phantom-api multihop status
```

**Response (Inactive):**
```json
{
  "success": true,
  "data": {
    "enabled": false,
    "active_exit": null,
    "available_configs": 1,
    "vpn_interface": {
      "active": false,
      "error": "VPN interface not active"
    },
    "monitor_status": {
      "monitoring": false,
      "type": null,
      "pid": null
    },
    "traffic_routing": "Direct",
    "traffic_flow": "Clients -> Phantom Server -> Internet (direct)"
  },
  "metadata": {
    "module": "multihop",
    "action": "status",
    "timestamp": "2025-09-09T01:16:37.646761Z",
    "version": "core-v1"
  }
}
```
