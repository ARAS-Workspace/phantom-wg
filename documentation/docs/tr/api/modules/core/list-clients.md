### İstemcileri Listele

```bash
# İlk 10 istemciyi listele
phantom-api core list_clients

# Sayfa başına 20 öğe ile 2. sayfayı listele
phantom-api core list_clients page=2 per_page=20

# İstemcileri ara
phantom-api core list_clients search="john"
```

**Parametreler:**

- `page` (opsiyonel, varsayılan=1): Sayfa numarası
- `per_page` (opsiyonel, varsayılan=10): Sayfa başına öğe sayısı
- `search` (opsiyonel): Arama terimi

**Yanıt:**
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
