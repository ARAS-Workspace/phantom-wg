### İstemci Kaldır

```bash
phantom-api core remove_client client_name="john-laptop"
```

**Parametreler:**

- `client_name` (zorunlu): Kaldırılacak istemcinin adı

**Yanıt:**
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
