### DNS Sunucularını Değiştir

Tüm istemcilerin kullanacağı birincil ve/veya ikincil DNS sunucularını günceller.
Değişiklik anında tüm istemci yapılandırmalarına yansır.

```bash
phantom-api dns change_dns_servers primary="1.1.1.1" secondary="1.0.0.1"
```

```bash
phantom-api dns change_dns_servers primary="8.8.8.8"
```

**Parametreler:**

| Parametre   | Zorunlu | Açıklama                   |
|-------------|---------|----------------------------|
| `primary`   | Hayır   | Birincil DNS sunucu IP'si  |
| `secondary` | Hayır   | İkincil DNS sunucu IP'si   |

!!! note
    En az bir parametre sağlanmalıdır. Belirtilmeyen parametreler mevcut değerlerini korur.

**Yanıt Modeli:** [`ChangeDNSResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/dns/models/dns_models.py#L54)

| Alan                             | Tip     | Açıklama                              |
|----------------------------------|---------|---------------------------------------|
| `success`                        | boolean | İşlem tamamlandı                      |
| `dns_servers.primary`            | string  | Yeni birincil DNS sunucusu            |
| `dns_servers.secondary`          | string  | Yeni ikincil DNS sunucusu             |
| `dns_servers.previous_primary`   | string  | Önceki birincil DNS sunucusu          |
| `dns_servers.previous_secondary` | string  | Önceki ikincil DNS sunucusu           |
| `client_configs_updated.success` | boolean | İstemci yapılandırmaları güncellendi  |
| `client_configs_updated.message` | string  | Güncelleme durum mesajı               |

??? example "Örnek Yanıt"
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
      }
    }
    ```
