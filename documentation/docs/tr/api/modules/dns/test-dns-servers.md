### DNS Sunucularını Test Et

Bir alan adını çözümleyerek DNS sunucularına bağlantıyı test eder.

```bash
phantom-api dns test_dns_servers
```

```bash
phantom-api dns test_dns_servers servers='["8.8.8.8","1.1.1.1"]'
```

```bash
phantom-api dns test_dns_servers domain="example.com"
```

**Parametreler:**

| Parametre | Zorunlu | Açıklama                                           |
|-----------|---------|----------------------------------------------------|
| `servers` | Hayır   | Test edilecek DNS sunucularının JSON dizisi        |
| `domain`  | Hayır   | Çözümlenecek alan adı (varsayılan: "google.com")   |

**Yanıt Modeli:** [`TestDNSResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/dns/models/dns_models.py#L92)

| Alan                         | Tip     | Açıklama                         |
|------------------------------|---------|----------------------------------|
| `all_passed`                 | boolean | Tüm sunucular testi geçti        |
| `servers_tested`             | integer | Test edilen sunucu sayısı        |
| `results[].server`           | string  | DNS sunucu adresi                |
| `results[].success`          | boolean | Test başarılı                    |
| `results[].status`           | string  | Durum mesajı                     |
| `results[].response_time_ms` | float   | Milisaniye cinsinden yanıt süresi|
| `results[].test_domain`      | string  | Test için kullanılan alan adı    |
| `results[].error`            | string  | Başarısızsa hata mesajı          |

??? example "Örnek Yanıt"
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
      }
    }
    ```
