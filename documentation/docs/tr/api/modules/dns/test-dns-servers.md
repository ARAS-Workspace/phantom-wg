### DNS Sunucularını Test Et

```bash
# Yapılandırılmış sunucuları test et
phantom-api dns test_dns_servers

# Belirli sunucuları test et
phantom-api dns test_dns_servers servers='["8.8.8.8","1.1.1.1"]'

# Belirli bir alan adı ile test et
phantom-api dns test_dns_servers domain="example.com"
```

**Parametreler:**

- `servers` (opsiyonel): DNS sunucularının JSON dizisi
- `domain` (opsiyonel, varsayılan="google.com"): Test alan adı

**Yanıt:**
```json
{
  "success": true,
  "data": {
    "all_passed": true,
    "servers_tested": 2,
    "results": [
      {
        "server": "1.1.1.1",
        "success": true,
        "status": "OK",
        "response_time_ms": null,
        "test_domain": "google.com"
      },
      {
        "server": "1.0.0.1",
        "success": true,
        "status": "OK",
        "response_time_ms": null,
        "test_domain": "google.com"
      }
    ]
  },
  "metadata": {
    "module": "dns",
    "action": "test_dns_servers",
    "timestamp": "2025-07-11T05:17:44.423898Z",
    "version": "core-v1"
  }
}
```
