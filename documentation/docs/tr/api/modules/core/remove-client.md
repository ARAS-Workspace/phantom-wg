### İstemci Kaldır

Sunucudan bir WireGuard istemcisini kaldırır.

```bash
phantom-api core remove_client client_name="john-laptop"
```

**Parametreler:**

| Parametre     | Zorunlu | Açıklama                      |
|---------------|---------|-------------------------------|
| `client_name` | Evet    | Kaldırılacak istemcinin adı   |

**Yanıt Modeli:** [`ClientRemoveResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/core/models/client_models.py#L133)

| Alan          | Tip     | Açıklama                        |
|---------------|---------|---------------------------------|
| `removed`     | boolean | Kaldırma işleminin başarı durumu|
| `client_name` | string  | Kaldırılan istemcinin adı       |
| `client_ip`   | string  | Kaldırılan istemcinin IP adresi |

??? example "Örnek Yanıt"
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
