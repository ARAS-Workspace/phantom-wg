### Ghost Mode'u Devre Dışı Bırak

```bash
phantom-api ghost disable
```

**Yanıt:**
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

**Notlar:**

- Port 51820'de doğrudan WireGuard bağlantısını geri yükler
- Tüm istemciler otomatik olarak normal WireGuard yapılandırmasına döner
