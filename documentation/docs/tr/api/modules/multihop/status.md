### Multihop Durumu

```bash
phantom-api multihop status
```

**Yanıt (Pasif):**
```json
{
  "success": true,
  "data": {
    "enabled": false,
    "active_exit": null,
    "available_configs": 1,
    "vpn_interface": {
      "active": false,
      "error": "VPN arayüzü aktif değil"
    },
    "monitor_status": {
      "monitoring": false,
      "type": null,
      "pid": null
    },
    "traffic_routing": "Doğrudan",
    "traffic_flow": "İstemciler -> Phantom Sunucusu -> İnternet (doğrudan)"
  },
  "metadata": {
    "module": "multihop",
    "action": "status",
    "timestamp": "2025-09-09T01:16:37.646761Z",
    "version": "core-v1"
  }
}
```
