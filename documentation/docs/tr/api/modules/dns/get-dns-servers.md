### DNS Sunucularını Al

Yapılandırılmış birincil ve ikincil DNS sunucularını alır.

```bash
phantom-api dns get_dns_servers
```

**Yanıt Modeli:** [`GetDNSServersResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/dns/models/dns_models.py#L173)

| Alan        | Tip    | Açıklama                |
|-------------|--------|-------------------------|
| `primary`   | string | Birincil DNS sunucusu   |
| `secondary` | string | İkincil DNS sunucusu    |

??? example "Örnek Yanıt"
    ```json
    {
      "success": true,
      "data": {
        "primary": "8.8.8.8",
        "secondary": "1.1.1.1"
      }
    }
    ```
