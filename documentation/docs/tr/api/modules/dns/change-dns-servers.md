### DNS Sunucularını Değiştir

Tüm istemcilerin kullanacağı birincil ve/veya ikincil DNS sunucularını günceller.
Değişiklik anında tüm istemci yapılandırmalarına yansır.

```bash
# Her iki DNS sunucusunu değiştir
phantom-api dns change_dns_servers primary="1.1.1.1" secondary="1.0.0.1"

# Sadece birincil DNS'i değiştir
phantom-api dns change_dns_servers primary="8.8.8.8"
```

**Parametreler:**

- `primary` (opsiyonel): Birincil DNS sunucu IP'si
- `secondary` (opsiyonel): İkincil DNS sunucu IP'si

**Yanıt:**
```json
{
  "success": true,
  "data": {
    "success": true,
    "dns_servers": {
      "primary": "1.1.1.1",
      "secondary": "1.0.0.1",
      "previous_primary": "8.8.8.8",
      "previous_secondary": "1.1.1.1"
    },
    "client_configs_updated": {
      "success": true,
      "message": "DNS configuration updated globally"
    }
  },
  "metadata": {
    "module": "dns",
    "action": "change_dns_servers",
    "timestamp": "2025-07-11T05:17:32.309051Z",
    "version": "core-v1"
  }
}
```
