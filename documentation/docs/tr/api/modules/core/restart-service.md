### Servisi Yeniden Başlat

**Dikkat:** Yeniden başlatma sırasında bağlı tüm istemcilerin bağlantısı geçici olarak kesilir.

```bash
phantom-api core restart_service
```

**Yanıt:**
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
