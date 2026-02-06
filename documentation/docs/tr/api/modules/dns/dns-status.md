### DNS Durumu

Yapılandırılmış sunuculara bağlantı testleri dahil DNS yapılandırmasını ve sağlık durumunu alır.

```bash
phantom-api dns status
```

**Yanıt Modeli:** [`DNSStatusResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/dns/models/dns_models.py#L161)

| Alan                                | Tip     | Açıklama                         |
|-------------------------------------|---------|----------------------------------|
| `configuration.primary`             | string  | Birincil DNS sunucusu            |
| `configuration.secondary`           | string  | İkincil DNS sunucusu             |
| `health.status`                     | string  | Genel sağlık durumu              |
| `health.test_results[].server`      | string  | Test edilen DNS sunucusu         |
| `health.test_results[].tests[].domain`   | string | Test edilen alan adı        |
| `health.test_results[].tests[].success`  | any    | Test sonucu (IP veya boolean)|
| `health.test_results[].tests[].response` | string | DNS yanıtı                  |
| `health.test_results[].tests[].error`    | string | Başarısızsa hata mesajı     |

??? example "Örnek Yanıt"
    ```json
    {
      "success": true,
      "data": {
        "mode": "standard",
        "configuration": {
          "primary": "1.1.1.1",
          "secondary": "1.0.0.1"
        },
        "health": {
          "status": "healthy",
          "test_results": [
            {
              "server": "1.1.1.1",
              "tests": [
                {
                  "domain": "google.com",
                  "success": "142.250.184.206",
                  "response": "142.250.184.206",
                  "error": null
                },
                {
                  "domain": "cloudflare.com",
                  "success": "104.16.133.229",
                  "response": "104.16.133.229",
                  "error": null
                }
              ]
            },
            {
              "server": "1.0.0.1",
              "tests": [
                {
                  "domain": "google.com",
                  "success": "142.250.184.206",
                  "response": "142.250.184.206",
                  "error": null
                },
                {
                  "domain": "cloudflare.com",
                  "success": "104.16.132.229",
                  "response": "104.16.132.229",
                  "error": null
                }
              ]
            }
          ]
        }
      }
    }
    ```
