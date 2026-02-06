### En Son Eklenen İstemciler

En son eklenen istemcileri döndürür.

```bash
phantom-api core latest_clients
```

```bash
phantom-api core latest_clients count=10
```

**Parametreler:**

| Parametre | Zorunlu | Varsayılan | Açıklama          |
|-----------|---------|------------|-------------------|
| `count`   | Hayır   | 5          | İstemci sayısı    |

**Yanıt Modeli:** [`LatestClientsResult`](https://github.com/ARAS-Workspace/phantom-wg/blob/main/phantom/modules/core/models/client_models.py#L167)

| Alan                         | Tip      | Açıklama                   |
|------------------------------|----------|----------------------------|
| `latest_clients`             | array    | Son istemciler listesi     |
| `latest_clients[].name`      | string   | İstemci adı                |
| `latest_clients[].ip`        | string   | Atanan IP adresi           |
| `latest_clients[].enabled`   | boolean  | Aktiflik durumu            |
| `latest_clients[].created`   | datetime | Oluşturulma zamanı         |
| `latest_clients[].connected` | boolean  | Mevcut bağlantı durumu     |
| `count`                      | integer  | Döndürülen istemci sayısı  |
| `total_clients`              | integer  | Sistemdeki toplam istemci  |

??? example "Örnek Yanıt"
    ```json
    {
      "success": true,
      "data": {
        "latest_clients": [
          {
            "name": "john-laptop",
            "ip": "10.8.0.2",
            "enabled": true,
            "created": "2025-09-09T01:14:22.076656",
            "connected": false
          }
        ],
        "count": 1,
        "total_clients": 1
      },
      "metadata": {
        "module": "core",
        "action": "latest_clients",
        "timestamp": "2025-09-09T01:15:00.000000Z",
        "version": "core-v1"
      }
    }
    ```
